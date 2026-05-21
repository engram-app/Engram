defmodule EngramWeb.VaultsControllerTest do
  use EngramWeb.ConnCase, async: true

  import Ecto.Query

  alias Engram.Accounts
  alias Engram.Vaults

  setup %{conn: conn} do
    user = insert(:user)
    # Give the user unlimited vaults for most tests
    insert(:user_limit_override, user: user, key: "vaults_cap", value: %{"v" => 10})
    {:ok, raw_key, _api_key} = Accounts.create_api_key(user, "test")
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
