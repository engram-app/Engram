defmodule EngramWeb.UsersControllerTest do
  use EngramWeb.ConnCase, async: false

  import Mox

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

      # Sibling-controller 422 shape (%{errors: field → [messages]}) — unified
      # from the old one-off %{error: "validation_failed", details: ...}.
      assert %{"errors" => %{"display_name" => [_ | _]}} = json_response(conn, 422)
    end

    test "401 without bearer" do
      conn = build_conn() |> patch("/api/me", %{display_name: "x"})
      assert response(conn, 401)
    end
  end

  describe "DELETE /api/me" do
    setup :set_mox_from_context
    setup :verify_on_exit!

    setup do
      # `create_user_with_password` assigns a Clerk-style external_id, so the
      # `Lifecycle.hard_delete` cascade calls `Clerk.ApiMock.delete_user/1`.
      # Stub it so it returns :ok without per-test expectations.
      stub(Engram.Auth.Clerk.ApiMock, :delete_user, fn _ -> :ok end)
      :ok
    end

    # The password rides the BODY. In a query string it is written to Phoenix's
    # and the load balancer's access logs and to the browser's Sentry fetch
    # breadcrumb — a credential the user typed into a confirm dialog, spread
    # across three log stores. This test is the contract that keeps the body
    # path working, so the frontend can never be pushed back to the query.
    test "200 with correct password in the request BODY, hard-deletes the user row", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me", %{password: "password123"})
      assert %{"ok" => true} = json_response(conn, 200)

      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)
    end

    # Kept working on purpose: an older cached SPA bundle is still out there
    # sending the query form, and breaking its delete would be worse than the
    # leak it causes. Remove once the bundle floor has moved.
    test "200 with correct password in the query string (legacy bundles)", %{user: user} do
      conn = auth_conn(user) |> delete("/api/me?password=password123")
      assert %{"ok" => true} = json_response(conn, 200)

      refute Engram.Repo.get(Engram.Accounts.User, user.id, skip_tenant_check: true)
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
