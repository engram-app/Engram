defmodule Engram.Repo.Migrations.NoteBodyColumnsNullablePrepExpand do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R8(b1) schema prep: let a later release stop writing the `notes` body
  ciphertext columns (`note_bodies` holds the body) while every release
  from this one on keeps working.

    * `notes_kind_shape_check` required `content_ciphertext` on a note. It
      is replaced by `notes_kind_shape_v2_check`, which requires the content
      ciphertext OR its nonce (the nonce stays written: the write fences
      compare it). Added NOT VALID, then VALIDATE (SHARE UPDATE EXCLUSIVE:
      reads and writes continue during the scan), then the old one dropped.
      Every existing row and every write of the previous release has the
      ciphertext, so the scan finds nothing.
    * `notes_crdt_head_invalidate` fired only on `UPDATE OF
      crdt_state_ciphertext`. It now fires on either CRDT column, when the
      nonce changes or a non-NULL ciphertext changes: a write that sets only
      the nonce (ciphertext NULL) still resets the head, and nulling the
      ciphertext alone (same nonce, same state) does not. Every write of
      the previous release changes both together, so it sees no difference.

  No DDL transaction, so the NOT VALID add (ACCESS EXCLUSIVE, brief) commits
  before the VALIDATE scan instead of holding the lock across it. One pinned
  connection, so the `lock_timeout` reaches every statement and is reset
  after (each `execute` could land on another pooled connection). Rerun-safe:
  a partial run is redone from the top. Calls no app module (N-1 gate).
  """

  @shape_v2 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v2_check CHECK (
    (kind = 'note'   AND path_hmac           IS NOT NULL
                     AND (content_ciphertext IS NOT NULL OR content_nonce IS NOT NULL)
                     AND title_ciphertext    IS NOT NULL
                     AND tags_ciphertext     IS NOT NULL
                     AND folder_hmac         IS NOT NULL)
    OR
    (kind = 'folder' AND path_hmac           IS NULL
                     AND content_ciphertext  IS NULL
                     AND title_ciphertext    IS NULL
                     AND tags_ciphertext     IS NULL
                     AND folder_hmac         IS NOT NULL)
  ) NOT VALID
  """

  @shape_v1 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_check CHECK (
    (kind = 'note'   AND path_hmac           IS NOT NULL
                     AND content_ciphertext  IS NOT NULL
                     AND title_ciphertext    IS NOT NULL
                     AND tags_ciphertext     IS NOT NULL
                     AND folder_hmac         IS NOT NULL)
    OR
    (kind = 'folder' AND path_hmac           IS NULL
                     AND content_ciphertext  IS NULL
                     AND title_ciphertext    IS NULL
                     AND tags_ciphertext     IS NULL
                     AND folder_hmac         IS NOT NULL)
  ) NOT VALID
  """

  def up do
    with_lock_timeout([
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v2_check",
      @shape_v2,
      "ALTER TABLE notes VALIDATE CONSTRAINT notes_kind_shape_v2_check",
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_check",
      """
      CREATE OR REPLACE TRIGGER notes_crdt_head_invalidate
      BEFORE UPDATE OF crdt_state_ciphertext, crdt_state_nonce ON notes
      FOR EACH ROW
      WHEN (NEW.crdt_state_nonce IS DISTINCT FROM OLD.crdt_state_nonce
        OR (NEW.crdt_state_ciphertext IS NOT NULL
          AND NEW.crdt_state_ciphertext IS DISTINCT FROM OLD.crdt_state_ciphertext))
      EXECUTE FUNCTION notes_null_crdt_head()
      """
    ])
  end

  # Back to 20260710190000's trigger and the original check (NOT VALID: a
  # row a later release wrote with only a nonce stays readable).
  def down do
    with_lock_timeout([
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_check",
      @shape_v1,
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v2_check",
      """
      CREATE OR REPLACE TRIGGER notes_crdt_head_invalidate
      BEFORE UPDATE OF crdt_state_ciphertext ON notes
      FOR EACH ROW
      WHEN (NEW.crdt_state_ciphertext IS DISTINCT FROM OLD.crdt_state_ciphertext)
      EXECUTE FUNCTION notes_null_crdt_head()
      """
    ])
  end

  defp with_lock_timeout(statements) do
    repo().checkout(fn ->
      repo().query!("SET lock_timeout = '5s'")

      try do
        Enum.each(statements, &repo().query!(&1, [], timeout: :infinity))
      after
        repo().query!("RESET lock_timeout")
      end
    end)
  end
end
