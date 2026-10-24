defmodule Engram.Repo.Migrations.AddPluginVersionToVaultsExpand do
  use Ecto.Migration

  @moduledoc """
  `vaults.plugin_version` / `plugin_version_seen_at`: the Obsidian-plugin
  version last reported on the vault's `sync:` channel join, refused or not
  (`Engram.Vaults.record_plugin_version/3`). `list_vaults` reads it to tell an
  MCP client that the vault's sync is blocked on a plugin update.

  Nullable, no default, no backfill: NULL means no version reported yet,
  which is true of every existing row. A metadata-only ALTER; purely additive.

  The vaults_changed UPDATE trigger names every column but change_seq and
  updated_at (20261021100600), so it is re-created with the two new ones: a
  recorded version must evict the `:vaults` cache on every node, or a
  list_vaults served by another node keeps the old answer. The stamp refresh
  writes at most hourly per vault, so it notifies at most that often.
  """

  @old_cols ~w(id user_id description slug client_id is_default deleted_at created_at
               name_ciphertext name_nonce name_hmac dek_version slug_hmac slug_suffixed
               purge_started_at)

  @new_cols @old_cols ++ ~w(plugin_version plugin_version_seen_at)

  def up do
    alter table(:vaults) do
      add :plugin_version, :text
      add :plugin_version_seen_at, :timestamptz
    end

    flush()
    replace_trigger(@new_cols)
  end

  def down do
    replace_trigger(@old_cols)

    alter table(:vaults) do
      remove :plugin_version
      remove :plugin_version_seen_at
    end
  end

  defp replace_trigger(cols) do
    old = Enum.map_join(cols, ", ", &"OLD.#{&1}")
    new = Enum.map_join(cols, ", ", &"NEW.#{&1}")

    execute "SET LOCAL lock_timeout = '5s'"

    execute """
    CREATE OR REPLACE TRIGGER vaults_cache_notify_1
    AFTER UPDATE ON vaults
    FOR EACH ROW WHEN (ROW(#{old}) IS DISTINCT FROM ROW(#{new}))
    EXECUTE FUNCTION notify_vaults_changed();
    """
  end
end
