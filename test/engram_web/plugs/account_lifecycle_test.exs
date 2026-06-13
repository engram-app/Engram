defmodule EngramWeb.Plugs.AccountLifecycleTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Accounts.User
  alias EngramWeb.Plugs.AccountLifecycle

  defp run(conn, user, method \\ "GET", path \\ "/api/notes/changes") do
    %{conn | method: method, request_path: path}
    |> Plug.Conn.assign(:current_user, user)
    |> AccountLifecycle.call([])
  end

  describe "deleted accounts" do
    test "410 Gone on any endpoint", %{conn: conn} do
      user = %User{id: 1, deleted_at: DateTime.utc_now()}
      conn = run(conn, user, "POST", "/api/api-keys")

      assert conn.halted
      assert json_response(conn, 410)["error"] == "account_deleted"
    end

    test "410 even on otherwise-exempt billing paths (deleted is terminal)", %{conn: conn} do
      user = %User{id: 1, deleted_at: DateTime.utc_now()}
      conn = run(conn, user, "GET", "/api/billing/status")

      assert conn.halted
      assert json_response(conn, 410)["error"] == "account_deleted"
    end

    test "deleted takes precedence over suspended", %{conn: conn} do
      user = %User{id: 1, deleted_at: DateTime.utc_now(), suspended_at: DateTime.utc_now()}
      assert json_response(run(conn, user), 410)["error"] == "account_deleted"
    end
  end

  describe "suspended accounts" do
    setup do
      %{user: %User{id: 2, suspended_at: DateTime.utc_now()}}
    end

    test "403 on a management-plane write", %{conn: conn, user: user} do
      conn = run(conn, user, "POST", "/api/api-keys")

      assert conn.halted
      assert json_response(conn, 403)["error"] == "account_suspended"
    end

    test "403 on vault data", %{conn: conn, user: user} do
      assert json_response(run(conn, user, "GET", "/api/notes/changes"), 403)["error"] ==
               "account_suspended"
    end

    test "GET /api/me is exempt (read own status)", %{conn: conn, user: user} do
      refute run(conn, user, "GET", "/api/me").halted
    end

    test "GET /api/onboarding/status is exempt", %{conn: conn, user: user} do
      refute run(conn, user, "GET", "/api/onboarding/status").halted
    end

    test "billing endpoints are exempt for self-reactivation (any method)", %{
      conn: conn,
      user: user
    } do
      refute run(conn, user, "GET", "/api/billing/status").halted
      refute run(conn, user, "POST", "/api/billing/reverse-cancel").halted
    end

    test "DELETE /api/me is NOT exempt (only GET status read)", %{conn: conn, user: user} do
      assert run(conn, user, "DELETE", "/api/me").halted
    end
  end

  describe "active accounts and missing user" do
    test "active user passes through", %{conn: conn} do
      refute run(conn, %User{id: 3, deleted_at: nil, suspended_at: nil}).halted
    end

    test "no current_user assigned passes through", %{conn: conn} do
      refute AccountLifecycle.call(conn, []).halted
    end
  end
end
