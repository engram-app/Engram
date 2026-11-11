# Shared with 20261111000000; see the file for why it is not in lib/.
Code.require_file("lock_timeout_retry.exs", __DIR__)

defmodule Engram.Repo.Migrations.AddNamesExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.LockTimeoutRetry

  @disable_ddl_transaction true
  @disable_migration_lock true

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

  One ALTER per table, each taking ACCESS EXCLUSIVE on its table for a
  catalog change only. They run through `LockTimeoutRetry`
  (lock_timeout_retry.exs): a 5 s `lock_timeout` per statement and a
  statement that hits it (55P03) retried twice, so a busy table does not
  crash boot. No DDL transaction, so each ALTER commits alone and no two of
  the three tables are ever locked together. Rerun-safe (`IF NOT EXISTS`).
  """

  def up, do: run_up(repo())
  def down, do: run_down(repo())

  @doc false
  # Public for `AddNamesLockTest`.
  def run_up(repo) do
    LockTimeoutRetry.with_lock_timeout(
      repo,
      Enum.map(["notes", "attachments"], fn table ->
        """
        ALTER TABLE #{table}
          ADD COLUMN IF NOT EXISTS name_ciphertext bytea,
          ADD COLUMN IF NOT EXISTS name_nonce bytea,
          ADD COLUMN IF NOT EXISTS name_hmac bytea,
          ADD COLUMN IF NOT EXISTS name_ci_hmac bytea,
          ADD COLUMN IF NOT EXISTS name_stamp bytea
        """
      end) ++
        [
          """
          ALTER TABLE folders
            ADD COLUMN IF NOT EXISTS name_ci_hmac bytea,
            ADD COLUMN IF NOT EXISTS name_stamp bytea,
            ADD COLUMN IF NOT EXISTS seq bigint,
            ADD COLUMN IF NOT EXISTS notes_cascaded boolean NOT NULL DEFAULT true
          """
        ]
    )
  end

  @doc false
  def run_down(repo) do
    LockTimeoutRetry.with_lock_timeout(
      repo,
      [
        """
        ALTER TABLE folders
          DROP COLUMN IF EXISTS notes_cascaded,
          DROP COLUMN IF EXISTS seq,
          DROP COLUMN IF EXISTS name_stamp,
          DROP COLUMN IF EXISTS name_ci_hmac
        """
      ] ++
        Enum.map(["attachments", "notes"], fn table ->
          """
          ALTER TABLE #{table}
            DROP COLUMN IF EXISTS name_stamp,
            DROP COLUMN IF EXISTS name_ci_hmac,
            DROP COLUMN IF EXISTS name_hmac,
            DROP COLUMN IF EXISTS name_nonce,
            DROP COLUMN IF EXISTS name_ciphertext
          """
        end)
    )
  end
end
