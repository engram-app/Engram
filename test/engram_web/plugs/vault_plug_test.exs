defmodule EngramWeb.Plugs.VaultPlugTest do
  use EngramWeb.ConnCase, async: false

  alias Engram.Accounts
  alias Engram.Vaults
  alias EngramWeb.Plugs.VaultPlug

  setup do
    user = insert(:user)
    other_user = insert(:user)

    {:ok, vault} =
      Vaults.create_vault(user, %{name: "My Vault", client_id: "client-abc"})

    {:ok, other_vault} =
      Vaults.create_vault(other_user, %{name: "Other Vault", client_id: "client-xyz"})

    %{user: user, other_user: other_user, vault: vault, other_vault: other_vault}
  end

  defp conn_with_user(user) do
    build_conn()
    |> assign(:current_user, user)
  end

  # ── Default vault resolution ───────────────────────────────────────────────

  describe "no X-Vault-ID header" do
    test "assigns default vault when user has one", %{user: user, vault: vault} do
      conn =
        conn_with_user(user)
        |> VaultPlug.call([])

      refute conn.halted
      assert conn.assigns.current_vault.id == vault.id
    end

    test "returns 404 when user has no vaults" do
      new_user = insert(:user)

      conn =
        conn_with_user(new_user)
        |> VaultPlug.call([])

      assert conn.halted
      assert conn.status == 404
      assert Jason.decode!(conn.resp_body)["error"] =~ "No vault configured"
    end
  end

  # ── Explicit X-Vault-ID header ─────────────────────────────────────────────

  describe "with X-Vault-ID header" do
    test "assigns vault when ID matches user's vault", %{user: user, vault: vault} do
      conn =
        conn_with_user(user)
        |> put_req_header("x-vault-id", to_string(vault.id))
        |> VaultPlug.call([])

      refute conn.halted
      assert conn.assigns.current_vault.id == vault.id
    end

    test "returns 404 when vault belongs to another user (no information leak)", %{
      user: user,
      other_vault: other_vault
    } do
      conn =
        conn_with_user(user)
        |> put_req_header("x-vault-id", to_string(other_vault.id))
        |> VaultPlug.call([])

      assert conn.halted
      # Returns 404, not 403, to avoid leaking vault existence
      assert conn.status == 404
    end

    test "returns 404 for non-existent vault ID", %{user: user} do
      conn =
        conn_with_user(user)
        |> put_req_header("x-vault-id", "00000000-0000-0000-0000-000000999999")
        |> VaultPlug.call([])

      assert conn.halted
      assert conn.status == 404
    end

    test "returns 404 for non-uuid vault ID", %{user: user} do
      conn =
        conn_with_user(user)
        |> put_req_header("x-vault-id", "not-an-int")
        |> VaultPlug.call([])

      assert conn.halted
      assert conn.status == 404
    end
  end

  # ── API key vault restriction ──────────────────────────────────────────────

  describe "API key access checks" do
    test "JWT auth (no current_api_key) always passes vault check", %{user: user, vault: vault} do
      # No :current_api_key in assigns → JWT path
      conn =
        conn_with_user(user)
        |> VaultPlug.call([])

      refute conn.halted
      assert conn.assigns.current_vault.id == vault.id
    end

    test "unrestricted API key (no api_key_vaults rows) can access any vault",
         %{user: user, vault: vault} do
      {:ok, _raw_key, api_key} = Accounts.create_api_key(user, "unrestricted")

      conn =
        conn_with_user(user)
        |> assign(:current_api_key, api_key)
        |> VaultPlug.call([])

      refute conn.halted
      assert conn.assigns.current_vault.id == vault.id
    end

    test "restricted API key with matching vault is allowed",
         %{user: user, vault: vault} do
      {:ok, _raw_key, api_key} = Accounts.create_api_key(user, "restricted")

      # Insert a vault restriction row directly
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(api_key.id), vault_id: Ecto.UUID.dump!(vault.id)}
      ])

      conn =
        conn_with_user(user)
        |> assign(:current_api_key, api_key)
        |> VaultPlug.call([])

      refute conn.halted
      assert conn.assigns.current_vault.id == vault.id
    end

    test "restricted API key without matching vault returns 403",
         %{user: user, vault: vault, other_vault: other_vault} do
      {:ok, _raw_key, api_key} = Accounts.create_api_key(user, "restricted-other")

      # Restrict to other_user's vault ID (some other vault_id not owned by user)
      Engram.Repo.insert_all("api_key_vaults", [
        %{api_key_id: Ecto.UUID.dump!(api_key.id), vault_id: Ecto.UUID.dump!(other_vault.id)}
      ])

      # Try to access user's own vault — not in the restriction set
      conn =
        conn_with_user(user)
        |> assign(:current_api_key, api_key)
        |> put_req_header("x-vault-id", to_string(vault.id))
        |> VaultPlug.call([])

      assert conn.halted
      assert conn.status == 403
    end
  end
end
