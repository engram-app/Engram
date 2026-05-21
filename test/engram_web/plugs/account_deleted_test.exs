defmodule EngramWeb.Plugs.AccountDeletedTest do
  use EngramWeb.ConnCase, async: true

  alias EngramWeb.Plugs.AccountDeleted

  describe "call/2" do
    test "returns 410 Gone when current_user.deleted_at is set", %{conn: conn} do
      user = %Engram.Accounts.User{id: 1, deleted_at: DateTime.utc_now()}

      conn =
        conn
        |> Plug.Conn.assign(:current_user, user)
        |> AccountDeleted.call([])

      assert conn.halted
      assert json_response(conn, 410)["error"] == "account_deleted"
    end

    test "passes through for active users", %{conn: conn} do
      user = %Engram.Accounts.User{id: 1, deleted_at: nil}

      result =
        conn
        |> Plug.Conn.assign(:current_user, user)
        |> AccountDeleted.call([])

      refute result.halted
    end

    test "passes through when no current_user is assigned", %{conn: conn} do
      refute AccountDeleted.call(conn, []).halted
    end
  end
end
