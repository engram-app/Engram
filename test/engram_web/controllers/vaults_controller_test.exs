defmodule EngramWeb.VaultsControllerTest do
  # async: false — the vault-limit tests read the global `:limits_enforced`
  # flag, which LimitsTest / RequireApi*Test flip via Application.put_env. Under
  # async this module can run concurrently with a flip and observe `:unlimited`
  # → 201 where 402 is expected. Reading global state means leaving the async
  # pool too, not just the writers. See engram-app/engram#183, #236.
  use EngramWeb.ConnCase, async: false

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Auth.DeviceFlow
  alias Engram.Vaults
  alias Engram.Vaults.WelcomeNote

  setup %{conn: conn} do
    user = insert(:user)
    # Give the user unlimited vaults for most tests
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
    grant_api_write!(user)
    conn = put_req_header(conn, "authorization", "Bearer #{raw_key}")
    {:ok, conn: conn, user: user}
  end

  describe "GET /api/vaults" do
    test "returns empty list for new user", %{conn: conn} do
      conn = get(conn, "/api/vaults")
      body = json_response(conn, 200)
      assert body["vaults"] == []
    end

    test "lists user's vaults", %{conn: conn, user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "My Vault", Ecto.UUID.generate())
      conn = get(conn, "/api/vaults")
      body = json_response(conn, 200)
      ids = Enum.map(body["vaults"], & &1["id"])
      assert vault.id in ids
    end

    test "does not include vaults of other users", %{conn: conn, user: user} do
      other_user = insert(:user)
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => 5})

      {:ok, other_vault, _} =
        Vaults.register_vault(other_user, "Other Vault", Ecto.UUID.generate())

      {:ok, _my_vault, _} = Vaults.register_vault(user, "My Vault", Ecto.UUID.generate())

      conn = get(conn, "/api/vaults")
      body = json_response(conn, 200)
      ids = Enum.map(body["vaults"], & &1["id"])
      refute other_vault.id in ids
    end

    test "returns 401 without auth", %{conn: conn} do
      conn =
        conn
        |> delete_req_header("authorization")
        |> get("/api/vaults")

      assert json_response(conn, 401)
    end

    test "returns suggested_vault_name when ?user_code= matches a pending device flow",
         %{conn: conn} do
      {:ok, auth} =
        DeviceFlow.start_device_flow("client_test", "My Obsidian Vault")

      conn = get(conn, "/api/vaults?user_code=#{auth.user_code}")
      body = json_response(conn, 200)
      assert body["suggested_vault_name"] == "My Obsidian Vault"
      assert body["user_code_valid"] == true
    end

    # A pending code with no hint is still a code the user can link with, so
    # it must report valid. /link keys its reject on `user_code_valid`, not on
    # a missing name — conflating the two is the bug this field exists to stop.
    test "suggested_vault_name is nil but the code is still valid when no hint was stored",
         %{conn: conn} do
      {:ok, auth} = DeviceFlow.start_device_flow("client_test")
      conn = get(conn, "/api/vaults?user_code=#{auth.user_code}")
      body = json_response(conn, 200)
      assert Map.has_key?(body, "suggested_vault_name")
      assert body["suggested_vault_name"] == nil
      assert body["user_code_valid"] == true
    end

    test "omits suggested_vault_name and user_code_valid when no user_code passed",
         %{conn: conn} do
      conn = get(conn, "/api/vaults")
      body = json_response(conn, 200)
      refute Map.has_key?(body, "suggested_vault_name")
      refute Map.has_key?(body, "user_code_valid")
    end

    test "reports user_code_valid false for unknown user_code", %{conn: conn} do
      conn = get(conn, "/api/vaults?user_code=ZZZZ-ZZZZ")
      body = json_response(conn, 200)
      assert body["suggested_vault_name"] == nil
      assert body["user_code_valid"] == false
    end

    test "reports user_code_valid false for an expired code", %{conn: conn} do
      {:ok, auth} = DeviceFlow.start_device_flow("client_test", "Stale Vault")
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)

      Engram.Repo.update_all(
        from(da in Engram.Auth.DeviceAuthorization, where: da.id == ^auth.id),
        [set: [expires_at: past]],
        skip_tenant_check: true
      )

      conn = get(conn, "/api/vaults?user_code=#{auth.user_code}")
      body = json_response(conn, 200)
      assert body["user_code_valid"] == false
      assert body["suggested_vault_name"] == nil
    end

    test "another user probing a code already claimed by someone else gets nil",
         %{conn: conn} do
      # First user claims by reading /vaults?user_code=
      {:ok, auth} =
        DeviceFlow.start_device_flow("client_test", "Sensitive Vault")

      conn1 = get(conn, "/api/vaults?user_code=#{auth.user_code}")
      assert json_response(conn1, 200)["suggested_vault_name"] == "Sensitive Vault"

      # Second user (different account, valid auth) probes the same code —
      # the row's viewer_user_id is locked to user 1, so user 2 gets nil.
      other_user = insert(:user)
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => 5})

      {:ok, other_raw_key, _api_key} =
        Engram.Accounts.create_api_key(other_user, "probe")

      grant_api_write!(other_user)

      conn2 =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_req_header("authorization", "Bearer #{other_raw_key}")
        |> get("/api/vaults?user_code=#{auth.user_code}")

      assert json_response(conn2, 200)["suggested_vault_name"] == nil
    end

    test "index includes note_count and attachment_count", %{conn: conn, user: user} do
      vault = insert(:vault, user: user)
      insert(:note, user: user, vault: vault)
      insert(:note, user: user, vault: vault)
      insert(:attachment, user: user, vault: vault)

      resp = conn |> get(~p"/api/vaults") |> json_response(200)
      row = Enum.find(resp["vaults"], &(&1["id"] == vault.id))

      assert row["note_count"] == 2
      assert row["attachment_count"] == 1
    end

    test "under a scoped grant lists only the granted vault", %{conn: conn} do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      granted = insert(:vault, user: user, slug: "granted", is_default: true)
      _hidden = insert(:vault, user: user, slug: "hidden")

      user = ensure_external_id(user)
      token = Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => [granted.id]})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/vaults")

      slugs = conn |> json_response(200) |> Map.fetch!("vaults") |> Enum.map(& &1["slug"])
      assert slugs == ["granted"]
    end

    test "an unscoped token still lists every vault", %{conn: conn} do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      _vault_a = insert(:vault, user: user, slug: "vault-a", is_default: true)
      _vault_b = insert(:vault, user: user, slug: "vault-b")

      user = ensure_external_id(user)
      token = Accounts.generate_jwt(user, %{"scope" => "mcp"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/vaults")

      slugs = conn |> json_response(200) |> Map.fetch!("vaults") |> Enum.map(& &1["slug"])
      assert Enum.sort(slugs) == ["vault-a", "vault-b"]
    end
  end

  # `POST /api/vaults` is gone — it created a vault per call with no
  # idempotency key. Its coverage (201, 402, 422 blank name) now lives in the
  # `POST /api/vaults/register` describe below, which additionally covers the
  # duplicate-client_id 200 that made the old endpoint redundant.

  describe "GET /api/vaults/:id" do
    test "returns vault by id", %{conn: conn, user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Fetched", Ecto.UUID.generate())
      conn = get(conn, "/api/vaults/#{vault.id}")
      body = json_response(conn, 200)
      assert body["vault"]["id"] == vault.id
      assert body["vault"]["name"] == "Fetched"
    end

    test "returns 404 for non-existent vault", %{conn: conn} do
      conn = get(conn, "/api/vaults/00000000-0000-0000-0000-000099999999")
      assert json_response(conn, 404)
    end

    test "returns 404 for another user's vault", %{conn: conn} do
      other_user = insert(:user)
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => 5})
      {:ok, other_vault, _} = Vaults.register_vault(other_user, "Other", Ecto.UUID.generate())

      conn = get(conn, "/api/vaults/#{other_vault.id}")
      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/vaults/:id" do
    test "updates vault name", %{conn: conn, user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Old Name", Ecto.UUID.generate())
      conn = patch(conn, "/api/vaults/#{vault.id}", %{name: "New Name"})
      body = json_response(conn, 200)
      assert body["vault"]["name"] == "New Name"
    end

    test "returns 404 for non-existent vault", %{conn: conn} do
      conn = patch(conn, "/api/vaults/00000000-0000-0000-0000-000099999999", %{name: "X"})
      assert json_response(conn, 404)
    end

    test "returns 422 with changeset errors for an invalid is_default", %{conn: conn, user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "Valid", Ecto.UUID.generate())
      conn = patch(conn, "/api/vaults/#{vault.id}", %{is_default: "banana"})
      assert %{"errors" => %{"is_default" => [_ | _]}} = json_response(conn, 422)
    end
  end

  describe "DELETE /api/vaults/:id" do
    test "soft-deletes vault and returns 200", %{conn: conn, user: user} do
      {:ok, vault, _} = Vaults.register_vault(user, "To Delete", Ecto.UUID.generate())
      conn = delete(conn, "/api/vaults/#{vault.id}")
      body = json_response(conn, 200)
      assert body["deleted"] == true
      assert body["id"] == vault.id

      # Verify it's gone from list
      assert Vaults.get_vault(user, vault.id) == {:error, :not_found}
    end

    test "returns 404 for non-existent vault", %{conn: conn} do
      conn = delete(conn, "/api/vaults/00000000-0000-0000-0000-000099999999")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/vaults?deleted=true" do
    test "lists soft-deleted vaults with a purge_at and content counts", %{conn: conn, user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "Trashed", Ecto.UUID.generate())
      insert(:note, user: user, vault: v)
      insert(:attachment, user: user, vault: v)
      {:ok, _} = Vaults.delete_vault(user, v.id)

      body = conn |> get("/api/vaults?deleted=true") |> json_response(200)
      [item] = body["vaults"]
      assert item["id"] == v.id
      assert item["deleted_at"]
      assert item["purge_at"]
      assert item["note_count"] == 1
      assert item["attachment_count"] == 1
    end

    test "active listing excludes deleted vaults", %{conn: conn, user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "Trashed", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)

      body = conn |> get("/api/vaults") |> json_response(200)
      assert body["vaults"] == []
    end

    test "under a scoped grant lists only the granted deleted vault", %{conn: conn} do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      granted = insert(:vault, user: user, slug: "granted", is_default: true)
      hidden = insert(:vault, user: user, slug: "hidden")
      {:ok, _} = Vaults.delete_vault(user, granted.id)
      {:ok, _} = Vaults.delete_vault(user, hidden.id)

      user = ensure_external_id(user)
      token = Accounts.generate_jwt(user, %{"scope" => "mcp", "vault_ids" => [granted.id]})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/vaults?deleted=true")

      slugs = conn |> json_response(200) |> Map.fetch!("vaults") |> Enum.map(& &1["slug"])
      assert slugs == ["granted"]
    end

    test "an unscoped token still lists every deleted vault", %{conn: conn} do
      user = insert(:user)
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      vault_a = insert(:vault, user: user, slug: "vault-a", is_default: true)
      vault_b = insert(:vault, user: user, slug: "vault-b")
      {:ok, _} = Vaults.delete_vault(user, vault_a.id)
      {:ok, _} = Vaults.delete_vault(user, vault_b.id)

      user = ensure_external_id(user)
      token = Accounts.generate_jwt(user, %{"scope" => "mcp"})

      conn =
        conn
        |> put_req_header("authorization", "Bearer #{token}")
        |> get("/api/vaults?deleted=true")

      slugs = conn |> json_response(200) |> Map.fetch!("vaults") |> Enum.map(& &1["slug"])
      assert Enum.sort(slugs) == ["vault-a", "vault-b"]
    end
  end

  describe "POST /api/vaults/:id/restore" do
    test "restores a deleted vault", %{conn: conn, user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "Back", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)

      body = conn |> post("/api/vaults/#{v.id}/restore") |> json_response(200)
      assert body["vault"]["id"] == v.id
    end

    test "returns 402 when over cap", %{conn: _conn} do
      # fresh user with default cap (1), no override
      other = insert(:user)
      {:ok, raw_key, _} = Engram.Accounts.create_api_key(other, "k")
      grant_api_write!(other)
      oconn = build_conn() |> put_req_header("authorization", "Bearer #{raw_key}")

      {:ok, first, _} = Vaults.register_vault(other, "First", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(other, first.id)
      {:ok, _, _} = Vaults.register_vault(other, "Replacement", Ecto.UUID.generate())

      body = oconn |> post("/api/vaults/#{first.id}/restore") |> json_response(402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "vaults_cap_exceeded"
      assert body["limit_key"] == "vaults_cap"
      assert body["limit"] == 1
      assert body["current"] == 1
    end

    test "returns 404 for an active vault", %{conn: conn, user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "Active", Ecto.UUID.generate())
      conn |> post("/api/vaults/#{v.id}/restore") |> json_response(404)
    end
  end

  describe "POST /api/vaults/:id/purge" do
    test "purges a deleted vault", %{conn: conn, user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "Doomed", Ecto.UUID.generate())
      {:ok, _} = Vaults.delete_vault(user, v.id)

      body = conn |> post("/api/vaults/#{v.id}/purge") |> json_response(200)
      assert body["purged"] == true
      assert body["id"] == v.id
    end

    test "returns 404 for an active vault", %{conn: conn, user: user} do
      {:ok, v, _} = Vaults.register_vault(user, "Active", Ecto.UUID.generate())
      conn |> post("/api/vaults/#{v.id}/purge") |> json_response(404)
    end
  end

  describe "POST /api/vaults/register" do
    test "creates vault on first call (201)", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: "My Mac", client_id: "mac-001"})
      body = json_response(conn, 201)
      assert body["name"] == "My Mac"
      assert is_binary(body["id"])
      assert body["status"] == "created"
    end

    test "returns 422 with blank name", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: "  ", client_id: "mac-blank"})

      assert json_response(conn, 422) == %{
               "errors" => %{"name" => ["can't be blank"]}
             }
    end

    test "returns existing vault on duplicate client_id (200)", %{conn: conn} do
      post(conn, "/api/vaults/register", %{name: "My Mac", client_id: "mac-dup"})
      conn2 = post(conn, "/api/vaults/register", %{name: "My Mac", client_id: "mac-dup"})
      body = json_response(conn2, 200)
      assert body["name"] == "My Mac"
      assert body["status"] == "existing"
    end

    test "seeds the welcome note on create", %{conn: conn, user: user} do
      conn = post(conn, "/api/vaults/register", %{name: "Seeded", client_id: "mac-seed"})
      body = json_response(conn, 201)

      # The request created the user's DEK. The setup struct predates it, so
      # every path lookup through it hashes with the wrong filter key and
      # misses. `Repo.get!` is NOT enough — the DEK is not a users column.
      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, vault} = Vaults.get_vault(user, body["id"])
      assert {:ok, note} = Engram.Notes.get_note(user, vault, WelcomeNote.path())
      assert note.content =~ "## Try these"
    end

    test "does not re-seed the welcome note on an existing vault", %{conn: conn, user: user} do
      body =
        conn
        |> post("/api/vaults/register", %{name: "Seeded", client_id: "mac-reseed"})
        |> json_response(201)

      {:ok, user} = Engram.Crypto.ensure_user_dek(user)
      {:ok, vault} = Vaults.get_vault(user, body["id"])
      :ok = Engram.Notes.delete_note(user, vault, WelcomeNote.path())

      post(conn, "/api/vaults/register", %{name: "Seeded", client_id: "mac-reseed"})
      |> json_response(200)

      # A deleted welcome note stays deleted. Re-seeding on the idempotent
      # path would resurrect a note the user threw away on every plugin retry.
      assert {:error, :not_found} = Engram.Notes.get_note(user, vault, WelcomeNote.path())
    end

    test "returns 402 when vault limit reached", %{conn: conn, user: user} do
      Engram.Repo.delete_all(
        from o in Engram.Billing.UserLimitOverride, where: o.user_id == ^user.id
      )

      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 1})
      # Re-grant API access after wiping all overrides above.
      grant_api_write!(user)

      {:ok, _, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())

      conn = post(conn, "/api/vaults/register", %{name: "New", client_id: "xyz"})
      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "vaults_cap_exceeded"
      assert body["limit_key"] == "vaults_cap"
      assert body["limit"] == 1
      assert body["current"] == 1
    end

    test "returns 400 when name or client_id missing", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: "No ID"})
      assert json_response(conn, 400)
    end

    # A blank client_id used to slip the is_nil guard, persist as NULL, and
    # miss its own lookup — so a client retrying with one got a NEW vault
    # every call instead of the same one.
    test "returns 400 for a blank client_id", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: "My Mac", client_id: ""})
      assert json_response(conn, 400)
    end

    # `slugify/1` assumed a binary: a JSON number for `name` passed the old
    # is_nil guard and raised on the way to a 500.
    test "returns 400 for a non-string name", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: 123, client_id: "mac-num"})
      assert json_response(conn, 400)
    end
  end

  # Free-tier launch §4.5 — standardized 402 shape via LimitResponse.halt/5
  describe "POST /api/vaults — Free tier vaults_cap exceeded" do
    setup %{conn: _conn} do
      # Fresh user with no vaults_cap override → falls through to the Free
      # default of 1 (lib/engram/billing/limit_keys.ex). Seed 1 vault so the
      # next create hits the cap with current == 1.
      user =
        insert(:user, free_tier_accepted_at: DateTime.utc_now(), suspended_at: nil)

      {:ok, raw_key, _} = Engram.Accounts.create_api_key(user, "ft-test-key")
      grant_api_write!(user)
      {:ok, _first, _} = Vaults.register_vault(user, "First", Ecto.UUID.generate())

      authed =
        build_conn()
        |> put_req_header("authorization", "Bearer #{raw_key}")

      %{conn: authed, user: user}
    end

    test "returns standardized 402 shape", %{conn: conn} do
      conn = post(conn, ~p"/api/vaults/register", %{name: "Second", client_id: "ft-second"})
      body = json_response(conn, 402)
      assert body["error"] == "limit_exceeded"
      assert body["reason"] == "vaults_cap_exceeded"
      assert body["tier"] == "free"
      assert body["limit_key"] == "vaults_cap"
      assert body["limit"] == 1
      assert body["current"] == 1
      assert body["upgrade_url"] =~ "/#settings/billing"
    end
  end

  defp ensure_external_id(%{external_id: ext} = user) when is_binary(ext) and ext != "", do: user

  defp ensure_external_id(user) do
    {:ok, updated} =
      user
      |> Ecto.Changeset.change(external_id: "test-#{user.id}")
      |> Engram.Repo.update(skip_tenant_check: true)

    updated
  end
end
