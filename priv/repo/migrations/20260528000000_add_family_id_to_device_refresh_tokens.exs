defmodule Engram.Repo.Migrations.AddFamilyIdToDeviceRefreshTokens do
  use Ecto.Migration

  # CONCURRENTLY index creation and the online-safe NOT NULL path (add the CHECK
  # NOT VALID, then VALIDATE separately) both require running outside a
  # transaction.
  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    alter table(:device_refresh_tokens) do
      add :family_id, :uuid
    end

    # Each existing token becomes its own family, so legacy tokens keep working
    # (reuse detection only nukes siblings, and a lone token has none).
    execute "UPDATE device_refresh_tokens SET family_id = gen_random_uuid() WHERE family_id IS NULL"

    # Enforce presence without a blocking full-table rewrite: add the constraint
    # NOT VALID (no scan, brief lock), then VALIDATE under a lighter lock. The
    # app always sets family_id; this is the DB-level backstop.
    execute """
    ALTER TABLE device_refresh_tokens
    ADD CONSTRAINT device_refresh_tokens_family_id_not_null
    CHECK (family_id IS NOT NULL) NOT VALID
    """

    execute "ALTER TABLE device_refresh_tokens VALIDATE CONSTRAINT device_refresh_tokens_family_id_not_null"

    create index(:device_refresh_tokens, [:family_id], concurrently: true)
  end

  def down do
    drop index(:device_refresh_tokens, [:family_id])

    execute "ALTER TABLE device_refresh_tokens DROP CONSTRAINT device_refresh_tokens_family_id_not_null"

    alter table(:device_refresh_tokens) do
      remove :family_id
    end
  end
end
