defmodule Engram.Repo.Migrations.AddNamesExpand do
  use Ecto.Migration

  @moduledoc """
  O(1) folder rename plan, S2 expand (Engram#2523): a note or attachment
  stores its own name next to its folder row reference, so a later release
  can derive its path from the folder chain plus the name.

    * `notes` / `attachments`: `name_ciphertext`, `name_nonce` (the last path
      segment, extension kept, AAD `aad_for_row(<table>, :name, id)`),
      `name_hmac` and `name_ci_hmac` (blind indexes in their own domains, the
      second casefolded), and `name_stamp`, the `path_nonce` the name came from
      plus a version byte (`Engram.Notes.Name`). A name is current only while
      its stamp matches the row's `path_nonce`, so a writer that rewrites the
      path without the name (the previous release) leaves a mismatch the
      `NoteName` ledger heals.
    * `folders`: `name_ci_hmac` plus its `name_stamp` (from `name_nonce`), a
      `seq` (the vault change seq of the folder's last structural change;
      written from S5 on) and `notes_cascaded` (true: the rename that wrote
      this row also rewrote its notes, as every writer up to S5 does).

  Nothing reads these until S3. Nullable, no default, except
  `notes_cascaded`, whose constant default is catalog-only (no rewrite). Calls
  no app module (N-1 gate).
  """

  def up do
    execute "SET lock_timeout = '5s'"

    for table <- ["notes", "attachments"] do
      execute """
      ALTER TABLE #{table}
        ADD COLUMN IF NOT EXISTS name_ciphertext bytea,
        ADD COLUMN IF NOT EXISTS name_nonce bytea,
        ADD COLUMN IF NOT EXISTS name_hmac bytea,
        ADD COLUMN IF NOT EXISTS name_ci_hmac bytea,
        ADD COLUMN IF NOT EXISTS name_stamp bytea
      """
    end

    execute """
    ALTER TABLE folders
      ADD COLUMN IF NOT EXISTS name_ci_hmac bytea,
      ADD COLUMN IF NOT EXISTS name_stamp bytea,
      ADD COLUMN IF NOT EXISTS seq bigint,
      ADD COLUMN IF NOT EXISTS notes_cascaded boolean NOT NULL DEFAULT true
    """

    execute "RESET lock_timeout"
  end

  def down do
    execute """
    ALTER TABLE folders
      DROP COLUMN IF EXISTS notes_cascaded,
      DROP COLUMN IF EXISTS seq,
      DROP COLUMN IF EXISTS name_stamp,
      DROP COLUMN IF EXISTS name_ci_hmac
    """

    for table <- ["attachments", "notes"] do
      execute """
      ALTER TABLE #{table}
        DROP COLUMN IF EXISTS name_stamp,
        DROP COLUMN IF EXISTS name_ci_hmac,
        DROP COLUMN IF EXISTS name_hmac,
        DROP COLUMN IF EXISTS name_nonce,
        DROP COLUMN IF EXISTS name_ciphertext
      """
    end
  end
end
