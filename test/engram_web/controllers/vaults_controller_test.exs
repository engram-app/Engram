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
      {:ok, vault} = Vaults.create_vault(user, %{name: "My Vault"})
      conn = get(conn, "/api/vaults")
      body = json_response(conn, 200)
      ids = Enum.map(body["vaults"], & &1["id"])
      assert vault.id in ids
    end

    test "does not include vaults of other users", %{conn: conn, user: user} do
      other_user = insert(:user)
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => 5})
      {:ok, other_vault} = Vaults.create_vault(other_user, %{name: "Other Vault"})
      {:ok, _my_vault} = Vaults.create_vault(user, %{name: "My Vault"})

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
    end

    test "suggested_vault_name is nil when user_code has no hint stored", %{conn: conn} do
      {:ok, auth} = DeviceFlow.start_device_flow("client_test")
      conn = get(conn, "/api/vaults?user_code=#{auth.user_code}")
      body = json_response(conn, 200)
      assert Map.has_key?(body, "suggested_vault_name")
      assert body["suggested_vault_name"] == nil
    end

    test "omits suggested_vault_name when no user_code passed", %{conn: conn} do
      conn = get(conn, "/api/vaults")
      body = json_response(conn, 200)
      refute Map.has_key?(body, "suggested_vault_name")
    end

    test "returns nil suggested_vault_name for unknown user_code", %{conn: conn} do
      conn = get(conn, "/api/vaults?user_code=ZZZZ-ZZZZ")
      body = json_response(conn, 200)
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
  end

  describe "POST /api/vaults" do
    test "creates a vault and returns 201", %{conn: conn} do
      conn = post(conn, "/api/vaults", %{name: "Work Notes"})
      body = json_response(conn, 201)
      assert body["vault"]["name"] == "Work Notes"
      assert is_integer(body["vault"]["id"])
      assert is_binary(body["vault"]["slug"])
    end

    test "returns 402 when vault limit reached", %{conn: conn, user: user} do
      # Override to limit of 1
      Engram.Repo.delete_all(
        from o in Engram.Billing.UserLimitOverride, where: o.user_id == ^user.id
      )

      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 1})
      # Re-grant API access after wiping all overrides above.
      grant_api_write!(user)

      {:ok, _} = Vaults.create_vault(user, %{name: "First"})

      conn = post(conn, "/api/vaults", %{name: "Second"})
      body = json_response(conn, 402)
      assert body["error"] == "vault_limit_reached"
      assert is_integer(body["limit"])
    end

    test "returns 422 with missing name", %{conn: conn} do
      conn = post(conn, "/api/vaults", %{})
      assert json_response(conn, 422)
    end
  end

  describe "GET /api/vaults/:id" do
    test "returns vault by id", %{conn: conn, user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Fetched"})
      conn = get(conn, "/api/vaults/#{vault.id}")
      body = json_response(conn, 200)
      assert body["vault"]["id"] == vault.id
      assert body["vault"]["name"] == "Fetched"
    end

    test "returns 404 for non-existent vault", %{conn: conn} do
      conn = get(conn, "/api/vaults/99999999")
      assert json_response(conn, 404)
    end

    test "returns 404 for another user's vault", %{conn: conn} do
      other_user = insert(:user)
      insert(:user_limit_override, user: other_user, key: "vaults_cap", value: %{"v" => 5})
      {:ok, other_vault} = Vaults.create_vault(other_user, %{name: "Other"})

      conn = get(conn, "/api/vaults/#{other_vault.id}")
      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/vaults/:id" do
    test "updates vault name", %{conn: conn, user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "Old Name"})
      conn = patch(conn, "/api/vaults/#{vault.id}", %{name: "New Name"})
      body = json_response(conn, 200)
      assert body["vault"]["name"] == "New Name"
    end

    test "returns 404 for non-existent vault", %{conn: conn} do
      conn = patch(conn, "/api/vaults/99999999", %{name: "X"})
      assert json_response(conn, 404)
    end
  end

  describe "DELETE /api/vaults/:id" do
    test "soft-deletes vault and returns 200", %{conn: conn, user: user} do
      {:ok, vault} = Vaults.create_vault(user, %{name: "To Delete"})
      conn = delete(conn, "/api/vaults/#{vault.id}")
      body = json_response(conn, 200)
      assert body["deleted"] == true
      assert body["id"] == vault.id

      # Verify it's gone from list
      assert Vaults.get_vault(user, vault.id) == {:error, :not_found}
    end

    test "returns 404 for non-existent vault", %{conn: conn} do
      conn = delete(conn, "/api/vaults/99999999")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/vaults?deleted=true" do
    test "lists soft-deleted vaults with a purge_at and content counts", %{conn: conn, user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "Trashed"})
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
      {:ok, v} = Vaults.create_vault(user, %{name: "Trashed"})
      {:ok, _} = Vaults.delete_vault(user, v.id)

      body = conn |> get("/api/vaults") |> json_response(200)
      assert body["vaults"] == []
    end
  end

  describe "POST /api/vaults/:id/restore" do
    test "restores a deleted vault", %{conn: conn, user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "Back"})
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

      {:ok, first} = Vaults.create_vault(other, %{name: "First"})
      {:ok, _} = Vaults.delete_vault(other, first.id)
      {:ok, _} = Vaults.create_vault(other, %{name: "Replacement"})

      body = oconn |> post("/api/vaults/#{first.id}/restore") |> json_response(402)
      assert body["error"] == "vault_limit_reached"
    end

    test "returns 404 for an active vault", %{conn: conn, user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "Active"})
      conn |> post("/api/vaults/#{v.id}/restore") |> json_response(404)
    end
  end

  describe "POST /api/vaults/:id/purge" do
    test "purges a deleted vault", %{conn: conn, user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "Doomed"})
      {:ok, _} = Vaults.delete_vault(user, v.id)

      body = conn |> post("/api/vaults/#{v.id}/purge") |> json_response(200)
      assert body["purged"] == true
      assert body["id"] == v.id
    end

    test "returns 404 for an active vault", %{conn: conn, user: user} do
      {:ok, v} = Vaults.create_vault(user, %{name: "Active"})
      conn |> post("/api/vaults/#{v.id}/purge") |> json_response(404)
    end
  end

  describe "POST /api/vaults/register" do
    test "creates vault on first call (201)", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: "My Mac", client_id: "mac-001"})
      body = json_response(conn, 201)
      assert body["name"] == "My Mac"
      assert is_integer(body["id"])
      assert body["status"] == "created"
    end

    test "returns existing vault on duplicate client_id (200)", %{conn: conn} do
      post(conn, "/api/vaults/register", %{name: "My Mac", client_id: "mac-dup"})
      conn2 = post(conn, "/api/vaults/register", %{name: "My Mac", client_id: "mac-dup"})
      body = json_response(conn2, 200)
      assert body["name"] == "My Mac"
      assert body["status"] == "existing"
    end

    test "returns 402 when vault limit reached", %{conn: conn, user: user} do
      Engram.Repo.delete_all(
        from o in Engram.Billing.UserLimitOverride, where: o.user_id == ^user.id
      )

      insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 1})
      # Re-grant API access after wiping all overrides above.
      grant_api_write!(user)

      {:ok, _} = Vaults.create_vault(user, %{name: "First"})

      conn = post(conn, "/api/vaults/register", %{name: "New", client_id: "xyz"})
      body = json_response(conn, 402)
      assert body["error"] == "vault_limit_reached"
    end

    test "returns 400 when name or client_id missing", %{conn: conn} do
      conn = post(conn, "/api/vaults/register", %{name: "No ID"})
      assert json_response(conn, 400)
    end
  end
end
