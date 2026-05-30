defmodule EngramWeb.ConnectionsControllerTest do
  use EngramWeb.ConnCase, async: false

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  # Issues a JWT via the local auth provider so it round-trips through
  # TokenResolver as a session JWT (not via the API-key code path). Mirrors
  # the pattern in auth_controller_test.exs.
  defp jwt_authed(conn, user) do
    user = ensure_external_id(user)
    {:ok, token} = Engram.Auth.Providers.Local.issue_access_token(user.external_id, user.email)
    put_req_header(conn, "authorization", "Bearer #{token}")
  end

  defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  defp ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end

  describe "GET /api/connections" do
    test "returns oauth + pat rows for the authenticated user", %{conn: conn} do
      user = insert(:user)
      client = insert(:oauth_client,
        kind: "mcp",
        software_id: "anthropic-claude-desktop",
        client_name: "Claude Desktop"
      )
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      # PAT rows: api_keys INSERT bypasses the tenant-gated SELECT check,
      # so factory insert works directly without with_tenant.
      insert(:api_key, user: user, name: "my-script")

      conn =
        conn
        |> jwt_authed(user)
        |> get("/api/connections")

      body = json_response(conn, 200)
      assert is_list(body)

      mcp = Enum.find(body, fn r -> r["kind"] == "mcp" end)
      assert mcp["name"] == "Claude Desktop"
      assert mcp["verified"] == true
      assert mcp["client_id"] == client.client_id

      pat = Enum.find(body, fn r -> r["kind"] == "pat" end)
      assert pat["name"] == "my-script"
      assert pat["client_id"] == nil
    end

    test "returns 401 without a session token", %{conn: conn} do
      conn = get(conn, "/api/connections")
      assert conn.status in [401, 403]
    end

    test "returns 403 for API-key-authed requests (PAT must not list connections)", %{conn: conn} do
      # The nested RequireSession plug gates the route. grant_api_write! lets
      # the request pass RequireApiRpsBudget so it reaches RequireSession,
      # which then returns 403 with api_key_not_allowed — matching the pattern
      # in auth_controller_test.exs.
      user = insert(:user)
      {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test-key")
      grant_api_write!(user)

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> get("/api/connections")

      assert %{"error" => "api_key_not_allowed"} = json_response(conn, 403)
    end

    test "returns [] for a user with no connections", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> jwt_authed(user)
        |> get("/api/connections")

      assert json_response(conn, 200) == []
    end
  end
end
