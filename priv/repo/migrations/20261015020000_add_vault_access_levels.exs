defmodule Engram.Repo.Migrations.AddVaultAccessLevels do
  use Ecto.Migration

  @moduledoc """
  Per-vault access levels for OAuth grants (#174) and API keys (#332).
  Nullable columns, no default, no backfill: metadata-only ALTERs.

  NULL keeps every existing row's current meaning, so nothing needs migrating:

    * `vault_access` (jsonb, `%{vault_id => "none" | "read" | "write"}`) and
      `default_access` (the level for vaults the grant does not list,
      including ones created later) on both OAuth grant tables. NULL on both
      is a pre-levels grant: its `vault_ids` are write, the rest none (or
      every vault write when `vault_ids` is NULL too). On a leveled grant
      `vault_ids` holds only its write-level listed ids, or the nil-UUID
      sentinel when it has none; never read-level ids. A reader that
      predates levels reads `vault_ids` as write, so it narrows rather than
      widens.
    * `api_keys.default_access`: NULL is a pre-levels key, where no
      `api_key_vaults` rows means every vault and rows mean exactly those.
    * `api_key_vaults.level`: NULL is write.
  """

  def change do
    for table <- [:oauth_authorization_codes, :oauth_refresh_tokens] do
      alter table(table) do
        add :vault_access, :map
        add :default_access, :text
      end
    end

    alter table(:api_keys) do
      add :default_access, :text
    end

    alter table(:api_key_vaults) do
      add :level, :text
    end
  end
end
