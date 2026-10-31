defmodule Engram.RepoStatementTimeoutTest do
  @moduledoc """
  Per-route-class server bounds (`EngramWeb.Plugs.StatementTimeout` ->
  `Engram.Repo.put_db_bounds/1` -> `SET LOCAL statement_timeout` and
  `lock_timeout` in the tenant-enter round trip), and what a bound reached
  does: it sheds (`Engram.Repo.ShedError`, 429 + retry-after), not a 500.
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.Repo

  defp show(user_id, setting) do
    Repo.with_tenant!(user_id, fn ->
      %{rows: [[v]]} = Repo.query!("SHOW #{setting}")
      v
    end)
  end

  test "a tenant transaction applies the process's bounds" do
    user = insert(:user)

    assert :ok = Repo.put_db_bounds(%{statement: 2_000, lock: 3_000})
    assert show(user.id, "statement_timeout") == "2s"
    assert show(user.id, "lock_timeout") == "3s"
  end

  test "with no bound set the session defaults stay" do
    user = insert(:user)
    assert :ok = Repo.put_db_bounds(nil)
    assert show(user.id, "statement_timeout") == "0"
  end

  test "the rotation-gated tenant enter carries the bounds too" do
    user = insert(:user)
    :ok = Repo.put_db_bounds(%{statement: 3_000, lock: 1_000})

    assert Engram.Crypto.RotationGate.gated(fn -> show(user.id, "statement_timeout") end) ==
             "3s"
  end

  # Counts every shed, by SQLSTATE name and route class.
  defp capture_sheds(fun) do
    test = self()
    id = {__MODULE__, make_ref()}

    :telemetry.attach(
      id,
      [:engram, :repo, :shed],
      fn _, %{count: 1}, meta, _ -> if self() == test, do: send(test, {:shed, meta}) end,
      nil
    )

    try do
      fun.()
    after
      :telemetry.detach(id)
    end
  end

  # A statement past its bound is often deterministic (a big vault, a bad
  # plan): a 503 the client parks on, never a 429 it would retry forever.
  test "a statement past the bound is cancelled: ShedError 503, counted" do
    user = insert(:user)
    :ok = Repo.put_db_bounds(%{statement: 50, lock: 50, class: :write})

    error =
      capture_sheds(fn ->
        assert_raise Engram.Repo.ShedError, fn ->
          Repo.with_tenant(user.id, fn -> Repo.query!("SELECT pg_sleep(0.5)") end)
        end
      end)

    assert error.code == :query_canceled
    assert Plug.Exception.status(error) == 503
    assert_received {:shed, %{code: :query_canceled, class: :write}}
  end

  # A lock held by another session past the request's lock bound is load:
  # a 429 the client retries after a short wait.
  test "a lock wait past the bound is ShedError 429, counted" do
    user = insert(:user)
    key = System.unique_integer([:positive])
    holder = hold_advisory_lock(key)

    try do
      :ok = Repo.put_db_bounds(%{statement: 5_000, lock: 50, class: :auth_read})

      error =
        capture_sheds(fn ->
          assert_raise Engram.Repo.ShedError, fn ->
            Repo.with_tenant(user.id, fn ->
              Repo.query!("SELECT pg_advisory_xact_lock($1)", [key])
            end)
          end
        end)

      assert error.code == :lock_not_available
      assert Plug.Exception.status(error) == 429
      assert_received {:shed, %{code: :lock_not_available, class: :auth_read}}
    after
      GenServer.stop(holder)
    end
  end

  # Another real session (outside the test sandbox) holding a session-level
  # advisory lock until stopped.
  def hold_advisory_lock(key) do
    {:ok, conn} = Postgrex.start_link(Engram.Application.repo_connection_opts())
    Postgrex.query!(conn, "SELECT pg_advisory_lock($1)", [key])
    conn
  end

  test "without a request bound a cancel stays a Postgrex error (workers rescue it)" do
    user = insert(:user)
    :ok = Repo.put_db_bounds(nil)

    assert_raise Postgrex.Error, fn ->
      Repo.with_tenant(user.id, fn ->
        Repo.query!("SET LOCAL statement_timeout = 50")
        Repo.query!("SELECT pg_sleep(0.5)")
      end)
    end
  end

  defp rendered(reason, status) do
    build_conn()
    |> Plug.Conn.assign(:reason, reason)
    |> EngramWeb.Plugs.RetryAfter.call([])
    |> Plug.Conn.send_resp(status, "")
    |> Plug.Conn.get_resp_header("retry-after")
  end

  # One 429 rule with the gate (#2359): a constant; the clients jitter.
  test "a lock shed gets the same constant retry-after as a gate shed" do
    assert rendered(%Engram.Repo.ShedError{code: :lock_not_available}, 429) ==
             [Integer.to_string(EngramWeb.Plugs.RetryAfter.busy_seconds())]
  end

  test "a statement-timeout shed gets NO retry-after, so the client parks" do
    assert rendered(%Engram.Repo.ShedError{code: :query_canceled}, 503) == []
  end

  # Like a gate shed: a warning and the counter, never Sentry or the error
  # log (a DB stall would otherwise send one event per request).
  test "neither shed is a server error to Sentry or the error log" do
    for code <- [:query_canceled, :lock_not_available] do
      refute Engram.Sentry.EventFilter.server_error?(%Engram.Repo.ShedError{code: code})
    end

    log =
      ExUnit.CaptureLog.capture_log(fn ->
        EngramWeb.RequestExceptionLogger.handle_event(
          [:bandit, :request, :exception],
          %{},
          %{exception: %Engram.Repo.ShedError{code: :query_canceled}, kind: :error},
          nil
        )
      end)

    assert log =~ "[warning] request shed at its DB bound: query_canceled"
    refute log =~ "[error]"
  end

  test "the shed counter is declared on the PromEx plugin" do
    metric =
      Engram.Test.PromExMetrics.of(Engram.PromEx.SeqGate)
      |> List.wrap()
      |> Enum.flat_map(& &1.metrics)
      |> Enum.find(&(&1.name == [:engram, :prom_ex, :seq_gate, :db_shed, :total]))

    assert metric.event_name == [:engram, :repo, :shed]
    assert metric.tags == [:code, :class]
  end

  test "the bounds come from the one config location" do
    assert %{statement: 3_000, lock: 3_000} = Engram.RuntimeConfig.request_db_bounds(:auth_read)
    assert %{statement: 5_000, lock: 3_000} = Engram.RuntimeConfig.request_db_bounds(:write)

    assert %{statement: 120_000, lock: 10_000} =
             Engram.RuntimeConfig.request_db_bounds(:account_delete)
  end

  describe "route classes" do
    setup :authed_api_conn

    # Every tenant_enter this request process issues, with its params.
    defp tenant_enters(fun) do
      test = self()
      id = {__MODULE__, make_ref()}

      :telemetry.attach(
        id,
        [:engram, :repo, :query],
        fn _, _, meta, _ ->
          if self() == test and meta[:source] == "tenant_enter",
            do: send(test, {:enter, meta[:params]})
        end,
        nil
      )

      try do
        fun.()
        collect([])
      after
        :telemetry.detach(id)
      end
    end

    defp collect(acc) do
      receive do
        {:enter, params} -> collect([params | acc])
      after
        0 -> Enum.reverse(acc)
      end
    end

    test "account reads get the short bound", %{conn: conn} do
      enters = tenant_enters(fn -> conn |> get(~p"/api/bootstrap") |> json_response(200) end)
      assert enters != []
      assert Enum.all?(enters, &match?([_, "3000ms", "3000ms"], &1)), inspect(enters)
    end

    test "vault writes get the write bound", %{conn: conn} do
      enters =
        tenant_enters(fn ->
          conn = post(conn, ~p"/api/notes", %{path: "t.md", content: "# t", mtime: 1.0})
          assert conn.status in 200..201
        end)

      assert enters != []
      assert Enum.all?(enters, &match?([_, "5000ms", "3000ms"], &1)), inspect(enters)
    end
  end
end
