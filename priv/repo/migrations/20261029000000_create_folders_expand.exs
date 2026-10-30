# squawk-ignore: require-concurrent-index-creation, prefer-bigint-over-smallint
# The indexes are on a table created in this migration (empty, nothing reads it);
# `dek_version` is a bounded code, like `notes.key_version` (int2).
defmodule Engram.Repo.Migrations.CreateFoldersExpand do
  use Ecto.Migration

  @moduledoc """
  Expand step of the folders table: folder
  identity as a row, so a folder is an id and its children point at it.

  One row per folder, adjacency list: `parent_id` NULL is the vault root (no
  sentinel row). `(vault_id, parent_id, name_hmac)` is unique among live
  folders; `NULLS NOT DISTINCT` (PG15+) makes two root folders of one name
  collide, which a plain unique index would let through.

  Names are encrypted exactly like `notes.folder_ciphertext`: AES-GCM under
  the owning account's per-user DEK, AAD `Crypto.aad_for_row(:folders, :name,
  id)` once `dek_version` is at the AAD-bound version. `name_hmac` is the
  segment's HMAC under the same filter key, in its own domain so it never
  equals a note's `path_hmac`.

  `full_path_hmac` is transitional: the HMAC of the whole path, the same value
  `notes.folder_hmac` holds, so the `notes_set_folder_ref` trigger (a later
  migration) can resolve a note's folder from the previous release's writes.
  Dropped at contract. It is NULL until a writer or the `FolderTable` data
  migration sets it.

  `(vault_id, id)` is unique so `notes` and `attachments` can reference a folder
  through a composite foreign key: the vault is part of the key, so a note can
  never point at another vault's folder.

  A new empty table: nothing reads or writes it yet, the previous release
  ignores it.

  Row security is the same pair every tenant table has: a tenant policy on
  `user_id` and its own `maintenance_all` for the maintenance role.
  """

  def up do
    execute "SET lock_timeout = '5s'"

    execute """
    CREATE TABLE folders (
      id uuid PRIMARY KEY DEFAULT uuidv7(),
      vault_id uuid NOT NULL REFERENCES vaults(id) ON DELETE CASCADE,
      user_id uuid NOT NULL,
      parent_id uuid,
      name_ciphertext bytea NOT NULL,
      name_nonce bytea NOT NULL,
      name_hmac bytea NOT NULL,
      full_path_hmac bytea,
      dek_version smallint NOT NULL,
      explicit boolean NOT NULL DEFAULT false,
      deleted_at timestamptz,
      delete_op_id uuid,
      inserted_at timestamptz NOT NULL DEFAULT now(),
      updated_at timestamptz NOT NULL DEFAULT now(),
      CONSTRAINT folders_vault_id_id_key UNIQUE (vault_id, id),
      CONSTRAINT folders_parent_fk FOREIGN KEY (vault_id, parent_id)
        REFERENCES folders (vault_id, id),
      CONSTRAINT folders_not_own_parent CHECK (parent_id IS DISTINCT FROM id)
    )
    """

    execute """
    CREATE UNIQUE INDEX folders_live_name ON folders (vault_id, parent_id, name_hmac)
      NULLS NOT DISTINCT WHERE deleted_at IS NULL
    """

    execute """
    CREATE INDEX folders_full_path ON folders (vault_id, full_path_hmac)
      WHERE full_path_hmac IS NOT NULL AND deleted_at IS NULL
    """

    # The per-user scans (data migration, DEK rotation) filter on user_id, like
    # idx_attachments_user and idx_chunks_user.
    execute "CREATE INDEX folders_user ON folders (user_id)"

    execute "ALTER TABLE folders ENABLE ROW LEVEL SECURITY"
    execute "ALTER TABLE folders FORCE ROW LEVEL SECURITY"

    execute """
    CREATE POLICY tenant_isolation_folders ON folders
      USING (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
      WITH CHECK (user_id = (SELECT NULLIF((SELECT current_setting('app.current_tenant', true)), '')::uuid))
    """

    execute """
    CREATE POLICY maintenance_all ON folders TO engram_maintenance
      USING (true) WITH CHECK (true)
    """

    execute "GRANT SELECT, INSERT, UPDATE, DELETE ON folders TO engram_app"
    execute "RESET lock_timeout"
  end

  def down do
    # The ledger must not outlive what it vouches for.
    execute "DELETE FROM data_migrations WHERE name = 'folder_table'"
    execute "DROP TABLE IF EXISTS folders"
  end
end
