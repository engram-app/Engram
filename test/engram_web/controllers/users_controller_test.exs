defmodule EngramWeb.UsersControllerTest do
  use EngramWeb.ConnCase, async: true

  describe "GET /me" do
    setup %{conn: conn} do
      user = insert(:user)
      {:ok, api_key, _} = Engram.Accounts.create_api_key(user, "test-key")
      grant_api_write!(user)
      authed = put_req_header(conn, "authorization", "Bearer #{api_key}")
      %{conn: authed, user: user}
    end

    test "returns current user", %{conn: conn, user: user} do
      conn = get(conn, "/api/me")
      assert %{"user" => %{"id" => id, "email" => email}} = json_response(conn, 200)
      assert id == user.id
      assert email == user.email
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> get("/api/me")

      assert json_response(conn, 401)
    end
  end
end
