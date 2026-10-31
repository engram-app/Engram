defmodule Engram.RepoStatementTimeoutTest do
  @moduledoc """
  Per-route-class server statement bound (`EngramWeb.Plugs.StatementTimeout`
  -> `Engram.Repo.put_statement_timeout/1` -> `SET LOCAL statement_timeout`
  in the tenant-enter round trip).
  """
  use EngramWeb.ConnCase, async: true

  alias Engram.Repo

  defp show_timeout(user_id) do
    Repo.with_tenant!(user_id, fn ->
      %{rows: [[v]]} = Repo.query!("SHOW statement_timeout")
      v
    end)
  end

  test "a tenant transaction applies the process's statement bound, and only then" do
    user = insert(:user)

    assert :ok = Repo.put_statement_timeout(2_000)
    assert show_timeout(user.id) == "2s"
  end

  test "with no bound set the session default stays" do
    user = insert(:user)
    assert :ok = Repo.put_statement_timeout(nil)
    assert show_timeout(user.id) == "0"
  end

  test "the rotation-gated tenant enter carries the bound too" do
    user = insert(:user)
    :ok = Repo.put_statement_timeout(3_000)

    assert Engram.Crypto.RotationGate.gated(fn -> show_timeout(user.id) end) == "3s"
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
      assert Enum.all?(enters, &match?([_, "2000ms"], &1)), inspect(enters)
    end

    test "vault writes get the write bound", %{conn: conn} do
      enters =
        tenant_enters(fn ->
          conn = post(conn, ~p"/api/notes", %{path: "t.md", content: "# t", mtime: 1.0})
          assert conn.status in 200..201
        end)

      assert enters != []
      assert Enum.all?(enters, &match?([_, "15000ms"], &1)), inspect(enters)
    end
  end
end
