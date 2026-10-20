defmodule Engram.Repo.Migrations.DropRedundantIndexes do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  # Dead or redundant indexes (2026-10-20 audit; prod scans since June in the
  # notes). None is unique, and every FK keeps a covering index:
  #
  #   * notes (user_id, vault_id, fm_timestamp) / (.., fm_created): 261 / 26
  #     scans, but nothing in lib/ filters on fm_* in Postgres (fm ranges run
  #     in Qdrant); the scans were the planner taking any (user_id, vault_id,
  #     ...) index for an unrelated vault lookup.
  #   * idx_notes_user_deleted (user_id, deleted_at) WHERE deleted_at IS NOT
  #     NULL: its readers, the delete-wins check and the rename link rewrite's
  #     old-path lookup, are by (vault_id, path_hmac) and now have
  #     notes_vault_path_tombstone_index (20261021090100).
  #   * idx_attachments_user (user_id): left prefix of attachments (user_id,
  #     vault_id, basename_hmac, path_length), which also covers the user FK.
  #   * user_limit_overrides_user_id_index: left prefix of UNIQUE (user_id,
  #     key), 0 scans.
  #   * device_authorizations_pending_user_code_index: user_code is UNIQUE,
  #     so there is at most one row to check the status of.
  #
  # Kept: idx_notes_user_updated (3,735 scans; per-tenant `ORDER BY
  # updated_at LIMIT` in the embed sweeps, v5 ground).
  # RedundantIndexesTest pins the replacements' plans.
  def up do
    drop_if_exists index(:notes, [:user_id, :vault_id, :fm_timestamp], concurrently: true)
    drop_if_exists index(:notes, [:user_id, :vault_id, :fm_created], concurrently: true)

    drop_if_exists index(:notes, [:user_id, :deleted_at],
                     name: :idx_notes_user_deleted,
                     concurrently: true
                   )

    drop_if_exists index(:attachments, [:user_id],
                     name: :idx_attachments_user,
                     concurrently: true
                   )

    drop_if_exists index(:user_limit_overrides, [:user_id], concurrently: true)

    drop_if_exists index(:device_authorizations, [:user_code],
                     name: :device_authorizations_pending_user_code_index,
                     concurrently: true
                   )
  end

  def down do
    create_if_not_exists index(:notes, [:user_id, :vault_id, :fm_timestamp], concurrently: true)
    create_if_not_exists index(:notes, [:user_id, :vault_id, :fm_created], concurrently: true)

    create_if_not_exists index(:notes, [:user_id, :deleted_at],
                           name: :idx_notes_user_deleted,
                           where: "deleted_at IS NOT NULL",
                           concurrently: true
                         )

    create_if_not_exists index(:attachments, [:user_id],
                           name: :idx_attachments_user,
                           concurrently: true
                         )

    create_if_not_exists index(:user_limit_overrides, [:user_id], concurrently: true)

    create_if_not_exists index(:device_authorizations, [:user_code],
                           name: :device_authorizations_pending_user_code_index,
                           where: "status = 'pending'",
                           concurrently: true
                         )
  end
end
