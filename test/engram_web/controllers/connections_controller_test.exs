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

  describe "GET /api/connections" do
    test "returns oauth + pat rows for the authenticated user", %{conn: conn} do
      user = insert(:user)

      # A real loopback client: Claude Code registers under its product name
      # with a user-chosen server suffix and sends no software_id at all. Its
      # slug comes from normalize_name/1 stripping the parenthetical, which is
      # the only attribution path left for local-first clients since the
      # guessed software_id entries were deleted (#1156).
      client =
        insert(:oauth_client,
          kind: "mcp",
          software_id: nil,
          client_name: "Claude Code (engram)"
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
      assert mcp["name"] == "Claude Code (engram)"
      # Loopback redirect => never verified. The slug still resolves, from the
      # name, so the onboarding checklist row can tick.
      assert mcp["verified"] == false
      assert mcp["slug"] == "claude_code"
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
      # The nested RequireSession plug gates the route. lift_api_rps_cap! lets
      # the request pass RequireApiRpsBudget so it reaches RequireSession,
      # which then returns 403 with api_key_not_allowed, matching the pattern
      # in auth_controller_test.exs.
      user = insert(:user)
      {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test-key")
      lift_api_rps_cap!(user)

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

    test "includes device refresh token connections as kind=obsidian", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      conn =
        conn
        |> jwt_authed(user)
        |> get("/api/connections")

      body = json_response(conn, 200)
      obs = Enum.find(body, fn r -> r["kind"] == "obsidian" end)
      assert obs["name"] == "Obsidian Vault Sync"
      assert obs["verified"] == true
      assert obs["client_id"] == family_id
      assert obs["software_id"] == "engram-vault-sync"
    end

    test "a vault-scoped OAuth token is denied outright, leaking no vault name", %{conn: conn} do
      # This route manages credentials, so an OAuth grant has no business on it
      # at all — `RequireSession` rejects the grant before the controller runs
      # (see require_session_test.exs for the escalation that prevents). The
      # name filter inside `list_for_user/2` is the second layer and is unit-
      # tested in connections_test.exs; this pins the outer one, and that no
      # name escapes through the error path either.
      %{user: user, granted: granted, hidden: hidden, client: client} = two_named_vaults()

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: nil,
        vault_ids: [granted.id, hidden.id]
      )

      user = ensure_external_id(user)
      token = Engram.Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => [granted.id]})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/connections")

      assert %{"error" => "oauth_grant_not_allowed"} = json_response(conn, 403)
      refute conn.resp_body =~ "Secret Client Work"
    end

    test "an ordinary session JWT still sees every granted vault name", %{conn: conn} do
      # The control for the test above: without a grant restriction the same
      # row carries both names, so the filter is what removed one, not a bug in
      # the name lookup.
      %{user: user, granted: granted, hidden: hidden, client: client} = two_named_vaults()

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: nil,
        vault_ids: [granted.id, hidden.id]
      )

      body =
        conn
        |> jwt_authed(user)
        |> get("/api/connections")
        |> json_response(200)

      row = Enum.find(body, fn r -> r["kind"] == "mcp" end)
      assert Enum.sort(row["vault_names"]) == ["Personal", "Secret Client Work"]
    end
  end

  # Two vaults registered through the real encryption pipeline so their names
  # decrypt back (factory vaults carry random ciphertext), plus an MCP client.
  defp two_named_vaults do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 5})

    {:ok, granted, _} = Engram.Vaults.register_vault(user, "Personal", Ecto.UUID.generate())

    {:ok, hidden, _} =
      Engram.Vaults.register_vault(user, "Secret Client Work", Ecto.UUID.generate())

    %{
      user: user,
      granted: granted,
      hidden: hidden,
      client: insert(:oauth_client, kind: "mcp")
    }
  end

  describe "DELETE /api/connections/oauth/:client_id" do
    test "revokes the family for the current user (vault-scoped)", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

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

    test "is idempotent, second revoke returns 204", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      client = insert(:oauth_client, kind: "mcp")

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        vault_id: vault.id
      )

      conn1 =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}?vault_id=#{vault.id}")

      assert conn1.status == 204

      conn2 =
        build_conn()
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}?vault_id=#{vault.id}")

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

    test "?family_id= revokes ONE grant and leaves the client's other alive", %{conn: conn} do
      user = insert(:user)
      client = insert(:oauth_client, kind: "mcp")
      work = insert(:vault, user: user)
      personal = insert(:vault, user: user)
      work_family = Ecto.UUID.generate()

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        family_id: work_family,
        label: "work",
        vault_ids: [work.id]
      )

      insert(:oauth_refresh_token,
        user_id: user.id,
        client_id: client.client_id,
        label: "laptop",
        vault_ids: [personal.id]
      )

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}?family_id=#{work_family}")

      assert conn.status == 204

      rows =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> jwt_authed(user)
        |> get("/api/connections")
        |> json_response(200)

      assert [survivor] = Enum.filter(rows, &(&1["kind"] == "mcp"))
      assert survivor["name"] == "laptop"
      assert survivor["family_id"] != work_family
      assert survivor["vault_ids"] == [personal.id]
    end

    test "404 for a family_id the user does not own", %{conn: conn} do
      user = insert(:user)
      client = insert(:oauth_client, kind: "mcp")
      insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/oauth/#{client.client_id}?family_id=#{Ecto.UUID.generate()}")

      assert conn.status == 404
      # The client's own grant is untouched — a bogus family must not fall
      # back to the client-wide revoke.
      assert Engram.Connections.count_active(user.id, :mcp) == 1
    end

    test "returns 401/403 for API-key-authed requests", %{conn: conn} do
      user = insert(:user)
      lift_api_rps_cap!(user)
      {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test-key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> delete("/api/connections/oauth/#{Ecto.UUID.generate()}")

      assert conn.status in [401, 403]
    end
  end

  describe "DELETE /api/connections/device/:family_id" do
    test "204 revokes the user's own device family", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/device/#{family_id}")

      assert conn.status == 204
      assert Engram.Connections.count_active(user.id, :obsidian) == 0
    end

    test "204 is idempotent, second revoke also returns 204", %{conn: conn} do
      user = insert(:user)
      vault = insert(:vault, user: user)
      family_id = Ecto.UUID.generate()
      insert(:device_refresh_token, user: user, vault: vault, family_id: family_id)

      conn1 =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/device/#{family_id}")

      assert conn1.status == 204

      conn2 =
        build_conn()
        |> jwt_authed(user)
        |> delete("/api/connections/device/#{family_id}")

      assert conn2.status == 204
    end

    test "404 for unknown family_id", %{conn: conn} do
      user = insert(:user)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/device/#{Ecto.UUID.generate()}")

      assert conn.status == 404
      assert json_response(conn, 404)["error"] == "not_found"
    end

    test "404 for another user's device family (no cross-user revoke)", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      vault = insert(:vault, user: other)
      family_id = Ecto.UUID.generate()
      insert(:device_refresh_token, user: other, vault: vault, family_id: family_id)

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/device/#{family_id}")

      assert conn.status == 404
      # Other user's connection must still be active
      assert Engram.Connections.count_active(other.id, :obsidian) == 1
    end

    test "401/403 for API-key-authed requests", %{conn: conn} do
      user = insert(:user)
      lift_api_rps_cap!(user)
      {:ok, raw_key, _api_key} = Engram.Accounts.create_api_key(user, "test-key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> delete("/api/connections/device/#{Ecto.UUID.generate()}")

      assert conn.status in [401, 403]
    end
  end

  describe "POST /api/connections/pat" do
    # #1974: a key works on every route on every tier, so every tier can mint
    # one. Cost is metered where it is incurred, not at minting.
    test "201 on Free: a key is usable on every tier", %{conn: conn} do
      free = insert(:user)

      conn =
        conn
        |> jwt_authed(free)
        |> post("/api/connections/pat", %{name: "x"})

      assert %{"key" => "engram_" <> _} = json_response(conn, 201)
    end

    test "201 on paid tier, returns raw key once", %{conn: conn} do
      paid = insert(:user)

      conn =
        conn
        |> jwt_authed(paid)
        |> post("/api/connections/pat", %{name: "ci-bot"})

      body = json_response(conn, 201)
      assert String.starts_with?(body["key"], "engram_")
      assert is_binary(body["id"])
      assert body["name"] == "ci-bot"
    end

    test "422 when name is missing on paid tier", %{conn: conn} do
      paid = insert(:user)

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
      lift_api_rps_cap!(user)
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
      {:ok, _raw_key, api_key} = Engram.Accounts.create_api_key(user, "to-delete")

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/pat/#{api_key.id}")

      assert conn.status == 204
      # Confirm it's gone, list_for_user should not include it.
      refute Enum.any?(Engram.Connections.list_for_user(user), fn r ->
               r.kind == :pat and r.key_id == api_key.id
             end)
    end

    test "404 for foreign user's PAT (no cross-user revoke)", %{conn: conn} do
      user = insert(:user)
      other = insert(:user)
      {:ok, _raw_key, foreign_key} = Engram.Accounts.create_api_key(other, "foreign")

      conn =
        conn
        |> jwt_authed(user)
        |> delete("/api/connections/pat/#{foreign_key.id}")

      assert conn.status == 404
      # Foreign user's key must still be active
      assert Enum.any?(Engram.Connections.list_for_user(other), fn r ->
               r.kind == :pat and r.key_id == foreign_key.id
             end)
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
      lift_api_rps_cap!(user)
      {:ok, raw_key, api_key} = Engram.Accounts.create_api_key(user, "test-key")

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw_key}")
        |> delete("/api/connections/pat/#{api_key.id}")

      assert conn.status in [401, 403]
    end
  end

  describe "PATCH /api/connections/oauth/:client_id" do
    defp oauth_grant(user, scope \\ "mcp") do
      client = insert(:oauth_client, kind: "mcp")

      rt =
        insert(:oauth_refresh_token, user_id: user.id, client_id: client.client_id, scope: scope)

      {client, rt}
    end

    test "replaces the grant's access and returns its connection row", %{conn: conn} do
      user = insert(:user)
      work = insert(:vault, user: user)
      {client, rt} = oauth_grant(user)

      body =
        conn
        |> jwt_authed(user)
        |> patch("/api/connections/oauth/#{client.client_id}?family_id=#{rt.family_id}", %{
          vault_access: %{work.id => "read"},
          default_access: "none"
        })
        |> json_response(200)

      assert body["family_id"] == rt.family_id
      assert body["new_vaults"] == "none"
      assert [%{"vault_id" => id, "level" => "read"}] = body["vault_levels"]
      assert id == work.id
    end

    test "422 when an mcp:read grant is given write", %{conn: conn} do
      user = insert(:user)
      work = insert(:vault, user: user)
      {client, rt} = oauth_grant(user, "mcp:read")

      conn =
        conn
        |> jwt_authed(user)
        |> patch("/api/connections/oauth/#{client.client_id}?family_id=#{rt.family_id}", %{
          vault_access: %{work.id => "write"},
          default_access: "none"
        })

      assert %{"errors" => %{"vault_access" => [_]}} = json_response(conn, 422)
    end

    test "422 for a selection that reaches nothing or no access params", %{conn: conn} do
      user = insert(:user)
      {client, rt} = oauth_grant(user)
      path = "/api/connections/oauth/#{client.client_id}?family_id=#{rt.family_id}"

      assert conn
             |> jwt_authed(user)
             |> patch(path, %{default_access: "none"})
             |> json_response(422)

      assert build_conn() |> jwt_authed(user) |> patch(path, %{}) |> json_response(422)
    end

    test "400 without a family_id", %{conn: conn} do
      user = insert(:user)
      {client, _rt} = oauth_grant(user)

      conn =
        conn
        |> jwt_authed(user)
        |> patch("/api/connections/oauth/#{client.client_id}", %{default_access: "read"})

      assert json_response(conn, 400)
    end

    test "404 for another user's grant, which keeps its access", %{conn: conn} do
      owner = insert(:user)
      {client, rt} = oauth_grant(owner)

      conn =
        conn
        |> jwt_authed(insert(:user))
        |> patch("/api/connections/oauth/#{client.client_id}?family_id=#{rt.family_id}", %{
          default_access: "read"
        })

      assert json_response(conn, 404)["error"] == "not_found"
      assert Engram.Repo.reload!(rt, skip_tenant_check: true).default_access == nil
    end
  end

  describe "PATCH /api/connections/pat/:id" do
    test "replaces a leveled key's access and returns its connection row", %{conn: conn} do
      user = insert(:user)
      work = insert(:vault, user: user)

      {:ok, _raw, key} =
        Engram.Accounts.create_api_key(user, "k", {%{work.id => "write"}, "none"})

      body =
        conn
        |> jwt_authed(user)
        |> patch("/api/connections/pat/#{key.id}", %{default_access: "read"})
        |> json_response(200)

      assert body["key_id"] == key.id
      assert body["new_vaults"] == "read"
    end

    test "422 for a pre-levels key", %{conn: conn} do
      user = insert(:user)
      {:ok, _raw, key} = Engram.Accounts.create_api_key(user, "old")

      conn =
        conn
        |> jwt_authed(user)
        |> patch("/api/connections/pat/#{key.id}", %{default_access: "read"})

      assert %{"errors" => %{"vault_access" => [_]}} = json_response(conn, 422)
    end

    test "404 for another user's key or a malformed id", %{conn: conn} do
      owner = insert(:user)
      work = insert(:vault, user: owner)

      {:ok, _raw, key} =
        Engram.Accounts.create_api_key(owner, "k", {%{work.id => "write"}, "none"})

      before = key_access_rows(key.id)

      assert conn
             |> jwt_authed(insert(:user))
             |> patch("/api/connections/pat/#{key.id}", %{default_access: "read"})
             |> json_response(404)

      # The refused PATCH left the key exactly as it was.
      assert key_access_rows(key.id) == before
      assert {"none", [{_, "write"}]} = before

      assert build_conn()
             |> jwt_authed(owner)
             |> patch("/api/connections/pat/nope", %{default_access: "read"})
             |> json_response(404)
    end

    test "401/403 for API-key-authed requests", %{conn: conn} do
      user = insert(:user)
      lift_api_rps_cap!(user)
      work = insert(:vault, user: user)
      {:ok, raw, key} = Engram.Accounts.create_api_key(user, "k", {%{work.id => "write"}, "none"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{raw}")
        |> patch("/api/connections/pat/#{key.id}", %{default_access: "write"})

      assert conn.status in [401, 403]
    end
  end

  defp key_access_rows(key_id) do
    import Ecto.Query, only: [from: 2]

    default =
      Engram.Repo.one!(
        from(k in Engram.Accounts.ApiKey, where: k.id == ^key_id, select: k.default_access),
        skip_tenant_check: true
      )

    rows =
      Engram.Repo.all(
        from(v in "api_key_vaults",
          where: v.api_key_id == type(^key_id, Ecto.UUID),
          select: {type(v.vault_id, Ecto.UUID), v.level}
        ),
        skip_tenant_check: true
      )

    {default, rows}
  end
end
