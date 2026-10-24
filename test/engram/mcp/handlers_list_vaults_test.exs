defmodule Engram.MCP.HandlersListVaultsTest do
  # A vault whose Obsidian plugin is below the floor is refused sync
  # (`plugin_upgrade_required`), so the AI must be able to tell the user to
  # update the plugin instead of guessing why notes are missing.
  use Engram.DataCase, async: true

  alias Engram.MCP.Handlers

  setup do
    user = insert(:user)
    {:ok, user} = Engram.Crypto.ensure_user_dek(user)
    {:ok, vault, _} = Engram.Vaults.register_vault(user, "V", Ecto.UUID.generate())
    %{user: user, vault: vault}
  end

  test "a vault last seen on an old plugin says sync is blocked", %{user: u, vault: v} do
    assert {:ok, text, %{"vaults" => [payload]}} =
             Handlers.handle(
               "list_vaults",
               u,
               [%{v | plugin_version: "1.20.0", plugin_version_seen_at: DateTime.utc_now()}],
               %{}
             )

    assert payload["sync_blocked"] == "plugin_upgrade_required"
    assert text =~ "update the Engram Vault Sync plugin"
    assert text =~ "1.36.0"
  end

  test "an old version last seen over a week ago no longer counts", %{user: u, vault: v} do
    seen = DateTime.add(DateTime.utc_now(), -8 * 86_400)

    assert {:ok, _, %{"vaults" => [payload]}} =
             Handlers.handle(
               "list_vaults",
               u,
               [%{v | plugin_version: "1.20.0", plugin_version_seen_at: seen}],
               %{}
             )

    refute Map.has_key?(payload, "sync_blocked")
  end

  test "a current or unknown plugin version carries no signal", %{user: u, vault: v} do
    for version <- ["1.36.0", nil] do
      assert {:ok, text, %{"vaults" => [payload]}} =
               Handlers.handle(
                 "list_vaults",
                 u,
                 [%{v | plugin_version: version, plugin_version_seen_at: DateTime.utc_now()}],
                 %{}
               )

      refute Map.has_key?(payload, "sync_blocked")
      refute text =~ "update"
    end
  end
end
