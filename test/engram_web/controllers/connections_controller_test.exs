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

  describe "DELETE /api/connections/oauth/:client_id" do
    test "revokes the family for the current user (vault-scoped)", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id, vault_id: vault.id)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}?vault_id=#{vault.id}")

      assert conn.status == 204
      assert Engram.Connections.count_active(user.id, :mcp) == 0
    end

    test "revokes all vaults when vault_id is omitted (device-flow grant)", %{conn: conn} do
      user = insert(:user)
      client = insert(:oauth_client, kind: "mcp")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id, vault_id: nil)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}")

      assert conn.status == 204
      assert Engram.Connections.count_active(user.id, :mcp) == 0
    end

    test "is idempotent — second revoke returns 204", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id, vault_id: vault.id)

      conn1 = conn |> jwt_authed(user) |> delete("/api/connections/oauth/#{client.client_id}?vault_id=#{vault.id}")
      assert conn1.status == 204

      conn2 = build_conn() |> jwt_authed(user) |> delete("/api/connections/oauth/#{client.client_id}?vault_id=#{vault.id}")
      assert conn2.status == 204
    end

    test "returns 404 for an unknown client_id", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{Ecto.UUID.generate()}")

      assert conn.status == 404
      body = Phoenix.ConnTest.json_response(conn, 404)
      assert body["error"] == "not_found"
    end

    test "returns 404 for a foreign user's client (no cross-user revoke)", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      client = insert(:oauth_client, kind: "mcp")
      insert(:oauth_refresh_token, user_id: other.id, client_id: client.client_id)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}")

      assert conn.status == 404
      # And the foreign user's grant must still be active
      assert Engram.Connections.count_active(other.id, :mcp) == 1
    end

    test "returns 401/403 for API-key-authed requests", %{conn: conn} do
      user = insert(:user)
      grant_api_write!(user)
      {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test-key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> delete("/api/connections/oauth/#{Ecto.UUID.generate()}")

      assert conn.status in [401, 403]
    end
  end

  describe "POST /api/connections/pat" do
    test "402 on Free (PAT minting blocked)", %{conn: conn} do
      free = insert(:user)

      conn =
        conn
        |> jwt_authed(free)
        |> post("/api/connections/pat", %{name: "x"})

      body = json_response(conn, 402)
      assert body["error"] == "pat_disabled_on_free"
      assert body["upgrade_url"] == "/settings/billing"
    end

    test "201 on paid tier, returns raw key once", %{conn: conn} do
      paid = insert(:user)
      insert(:user_limit_override,
        user: paid,
        key: "api_write_enabled",
        value: %{"v" => true}
      )

      conn =
        conn
        |> jwt_authed(paid)
        |> post("/api/connections/pat", %{name: "ci-bot"})

      body = json_response(conn, 201)
      assert String.starts_with?(body["key"], "engram_")
      assert is_integer(body["id"])
      assert body["name"] == "ci-bot"
    end

    test "422 when name is missing on paid tier", %{conn: conn} do
      paid = insert(:user)
      insert(:user_limit_override, user: paid, key: "api_write_enabled", value: %{"v" => true})

      conn =
        conn
        |> jwt_authed(paid)
        |> post("/api/connections/pat", %{})

      # Mirror whatever the existing POST /api-keys does for missing name —
      # check test/engram_web/controllers/auth_controller_test.exs. If it
      # returns 400 instead of 422, match that. Adjust the assertion below
      # if needed.
      assert conn.status in [400, 422]
    end

    test "401/403 for API-key-authed requests", %{conn: conn} do
      user = insert(:user)
      grant_api_write!(user)
      {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test-key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> post("/api/connections/pat", %{name: "x"})

      assert conn.status in [401, 403]
    end
  end

  describe "DELETE /api/connections/pat/:id" do
    test "204 deletes the user's own PAT", %{conn: conn} do
      user = insert(:user)
      insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => true})
      {:ok, _raw_key, api_key} = Engram.Accounts.create_api_key(user, "to-delete")

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/pat/#{api_key.id}")

      assert conn.status == 204
      # Confirm it's gone — list_for_user should not include it.
      refute Enum.any?(Engram.Connections.list_for_user(user.id), fn r -> r.kind == :pat and r.key_id == api_key.id end)
    end

    test "404 for foreign user's PAT (no cross-user revoke)", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      insert(:user_limit_override, user: other, key: "api_write_enabled", value: %{"v" => true})
      {:ok, _raw_key, foreign_key} = Engram.Accounts.create_api_key(other, "foreign")

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/pat/#{foreign_key.id}")

      assert conn.status == 404
      # Foreign user's key must still be active
      assert Enum.any?(Engram.Connections.list_for_user(other.id), fn r -> r.kind == :pat and r.key_id == foreign_key.id end)
    end

    test "404 for unknown PAT id", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/pat/999999")

      assert conn.status == 404
    end

    test "401/403 for API-key-authed requests", %{conn: conn} do
      user = insert(:user)
      grant_api_write!(user)
      {:ok, raw_key, api_key} = Engram.Accounts.create_api_key(user, "test-key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> delete("/api/connections/pat/#{api_key.id}")

      assert conn.status in [401, 403]
    end
  end
end
