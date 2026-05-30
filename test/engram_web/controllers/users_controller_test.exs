defmodule EngramWeb.UsersControllerTest do
  use EngramWeb.ConnCase, async: true

  alias Engram.Accounts

  defp auth_conn(user) do
    jwt = Accounts.generate_jwt(user)
    build_conn() |> put_req_header("authorization", "Bearer " <> jwt)
  end

  setup do
    # Bootstrap admin so members can exist without inheriting admin role.
    {:ok, _bootstrap} =
      Accounts.create_user_with_password("bootstrap-admin@example.com", "password123")

    {:ok, user} = Accounts.create_user_with_password("user@example.com", "password123")

    {:ok, user: user}
  end

  describe "GET /api/me" do
    test "returns id, email, role, display_name", %{user: user} do
      conn = auth_conn(user) |> get("/api/me")
      body = json_response(conn, 200)
      assert body["user"]["email"] == "user@example.com"
      assert body["user"]["role"] == "member"
      assert Map.has_key?(body["user"], "display_name")
    end
  end

  describe "PATCH /api/me" do
    test "updates display_name", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{display_name: "Pat"}))

      body = json_response(conn, 200)
      assert body["user"]["display_name"] == "Pat"
    end

    test "422 on too-long display_name", %{user: user} do
      conn =
        auth_conn(user)
        |> put_req_header("content-type", "application/json")
        |> patch("/api/me", Jason.encode!(%{display_name: String.duplicate("x", 81)}))

      assert %{"error" => "validation_failed"} = json_response(conn, 422)
    end

    test "401 without bearer" do
      conn = build_conn() |> patch("/api/me", %{display_name: "x"})
      assert response(conn, 401)
    end
  end

  describe "DELETE /api/me" do
    test "200 with correct password, soft-deletes", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me?password=password123")
      assert %{"ok" => true} = json_response(conn, 200)

      reloaded = Engram.Repo.get!(Engram.Accounts.User, user.id, skip_tenant_check: true)
      refute is_nil(reloaded.deleted_at)
    end

    test "403 on wrong password", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me?password=wrong")
      assert %{"error" => "invalid_password"} = json_response(conn, 403)
    end

    test "409 last_admin for the only admin" do
      {:ok, admin} = Accounts.find_by_normalized_email("bootstrap-admin@example.com")
      assert admin.role == "admin"

      conn = auth_conn(admin) |> delete("/api/me?password=password123")
      assert %{"error" => "last_admin"} = json_response(conn, 409)
    end

    test "400 when password param is missing", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me")
      assert %{"error" => "password_required"} = json_response(conn, 400)
    end
  end
end
