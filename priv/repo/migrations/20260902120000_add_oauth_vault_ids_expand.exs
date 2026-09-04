defmodule Engram.Repo.Migrations.AddOauthVaultIdsExpand do
  use Ecto.Migration

  # phase/expand — nullable array add, no default, no backfill. Safe under
  # Squawk: no table rewrite, no lock beyond the catalog update.
  #
  # NULL keeps its existing meaning ("all vaults"), so rows written before
  # this migration need no data migration — Engram.OAuth reads vault_ids
  # first and falls back to the scalar vault_id, which is retained until a
  # later phase/contract release drops it.
  def change do
    alter table(:oauth_authorization_codes) do
      add :vault_ids, {:array, :uuid}
    end

    alter table(:oauth_refresh_tokens) do
      add :vault_ids, {:array, :uuid}
    end
  end
end
