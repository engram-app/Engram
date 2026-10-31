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

  # The bound must actually cancel, and the cancel must read as load.
  test "a statement past the bound is cancelled and sheds as ShedError (429)" do
    user = insert(:user)
    :ok = Repo.put_db_bounds(%{statement: 50, lock: 50})

    error =
      assert_raise Engram.Repo.ShedError, fn ->
        Repo.with_tenant(user.id, fn -> Repo.query!("SELECT pg_sleep(0.5)") end)
      end

    assert error.code == :query_canceled
    assert Plug.Exception.status(error) == 429
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

  test "a shed request gets the same constant retry-after as a gate shed" do
    conn =
      build_conn()
      |> Plug.Conn.assign(:reason, %Engram.Repo.ShedError{code: :query_canceled})
      |> EngramWeb.Plugs.RetryAfter.call([])
      |> Plug.Conn.send_resp(429, "")

    assert Plug.Conn.get_resp_header(conn, "retry-after") ==
             [Integer.to_string(EngramWeb.Plugs.RetryAfter.busy_seconds())]
  end

  test "the bounds come from the one config location" do
    assert Engram.RuntimeConfig.request_db_bounds(:auth_read) == %{statement: 3_000, lock: 3_000}
    assert Engram.RuntimeConfig.request_db_bounds(:write) == %{statement: 5_000, lock: 3_000}
    assert Engram.RuntimeConfig.request_db_bounds(:cascade) == %{statement: 15_000, lock: 10_000}
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

    test "a vault delete keeps the cascade bound", %{conn: conn, user: user} do
      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => -1})
      {:ok, other, _} = Engram.Vaults.register_vault(user, "Other", Ecto.UUID.generate())

      enters = tenant_enters(fn -> delete(conn, ~p"/api/vaults/#{other.id}") end)
      assert enters != []
      assert Enum.any?(enters, &match?([_, "15000ms", "10000ms"], &1)), inspect(enters)
    end
  end
end
