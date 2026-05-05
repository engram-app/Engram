defmodule Engram.Crypto.CancelDecryptVaultTest do
  use Engram.DataCase, async: false

  alias Engram.Crypto
  alias Engram.Vaults.Vault

  setup do
    user = insert(:user)
    now = DateTime.utc_now()

    vault =
      insert(:vault,
        user: user,
        encrypted: true,
        encryption_status: "decrypt_pending",
        decrypt_requested_at: now,
        last_toggle_at: now
      )

    %{user: user, vault: vault}
  end

  describe "cancel_decrypt_vault/2" do
    test "flips vault back to encrypted and clears decrypt_requested_at", %{
      user: user,
      vault: vault
    } do
      original_toggle = vault.last_toggle_at
      assert {:ok, updated} = Crypto.cancel_decrypt_vault(vault, user)
      assert updated.encryption_status == "encrypted"
      assert is_nil(updated.decrypt_requested_at)
      # last_toggle_at unchanged — cooldown anchors on original decrypt request
      assert DateTime.compare(updated.last_toggle_at, original_toggle) == :eq
    end

    test "returns :bad_status when not in decrypt_pending", %{user: user, vault: vault} do
      {:ok, vault} = Vault.update_status(vault, "encrypted")
      assert {:error, :bad_status} = Crypto.cancel_decrypt_vault(vault, user)
    end
  end
end
