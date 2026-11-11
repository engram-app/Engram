defmodule Engram.Repo.Migrations.NotesBodyColumnsUnreferencedExpand do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R8(d) schema prep: no database object names `notes.content_ciphertext` or
  `notes.crdt_state_ciphertext` any more, so release E can drop the two
  columns. The body lives in `note_bodies` (R8(c) gave every note its row
  before boot), and no release from R8(b2) on writes the columns.

    * `notes_kind_shape_v3_check` named `content_ciphertext` in both
      branches. A plain DROP COLUMN would drop the whole check with it
      (path, title, tags and the marker's folder hash). It is replaced by
      `notes_kind_shape_v4_check`, identical but for those two clauses: a
      note's content clause (ciphertext or nonce) and a marker's NULL
      content. Only clauses are removed, so the check is strictly looser
      and the VALIDATE scan cannot fail. The nonce is not required instead:
      a pre-nonce note may still hold a NULL one.
    * `notes_crdt_head_invalidate` fired on `UPDATE OF crdt_state_ciphertext,
      crdt_state_nonce`; a plain DROP COLUMN of the CRDT ciphertext fails
      on that dependency. It now fires on a `crdt_state_nonce` change only.
      Every writer changes the nonce with the state (each encryption takes a
      fresh one), the 0.76 release that still writes the ciphertext included,
      so only a ciphertext-only write (nothing does one) stops resetting the
      head. R8(c)'s null batch still finds the trigger it checks for (its
      definition names `crdt_state_nonce`).

  NOT VALID add (ACCESS EXCLUSIVE, brief), then VALIDATE (SHARE UPDATE
  EXCLUSIVE: reads and writes continue), then the old check dropped. No DDL
  transaction, so the add commits before the scan. One pinned connection, so
  the `lock_timeout` reaches every statement and is reset after. Rerun-safe:
  a partial run is redone from the top. Calls no app module (N-1 gate).
  """

  @lock_retries 2

  @shape_v4 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v4_check CHECK (
    (kind = 'note'   AND path_hmac           IS NOT NULL
                     AND title_ciphertext    IS NOT NULL
                     AND tags_ciphertext     IS NOT NULL)
    OR
    (kind = 'folder' AND path_hmac           IS NULL
                     AND title_ciphertext    IS NULL
                     AND tags_ciphertext     IS NULL
                     AND folder_hmac         IS NOT NULL)
  ) NOT VALID
  """

  # 20261107130100's check, verbatim (migrations are frozen).
  @shape_v3 """
  ALTER TABLE notes ADD CONSTRAINT notes_kind_shape_v3_check CHECK (
    (kind = 'note'   AND path_hmac           IS NOT NULL
                     AND (content_ciphertext IS NOT NULL OR content_nonce IS NOT NULL)
                     AND title_ciphertext    IS NOT NULL
                     AND tags_ciphertext     IS NOT NULL)
    OR
    (kind = 'folder' AND path_hmac           IS NULL
                     AND content_ciphertext  IS NULL
                     AND title_ciphertext    IS NULL
                     AND tags_ciphertext     IS NULL
                     AND folder_hmac         IS NOT NULL)
  ) NOT VALID
  """

  def up do
    with_lock_timeout(repo(), [
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v4_check",
      @shape_v4,
      "ALTER TABLE notes VALIDATE CONSTRAINT notes_kind_shape_v4_check",
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v3_check",
      """
      CREATE OR REPLACE TRIGGER notes_crdt_head_invalidate
      BEFORE UPDATE OF crdt_state_nonce ON notes
      FOR EACH ROW
      WHEN (NEW.crdt_state_nonce IS DISTINCT FROM OLD.crdt_state_nonce)
      EXECUTE FUNCTION notes_null_crdt_head()
      """
    ])
  end

  # Back to 20261106110000's trigger and the v3 check (NOT VALID: a note a
  # later release wrote with neither content column stays readable).
  def down do
    with_lock_timeout(repo(), [
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v3_check",
      @shape_v3,
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v4_check",
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

  # `timeout: :infinity` on the checkout: without it DBConnection's 15 s
  # default is a deadline for the WHOLE block (a per-query timeout does not
  # extend it), and the VALIDATE scan plus a few lock waits can pass 15 s on a
  # busy table. That raises at boot, every task fails and the deploy rolls
  # back (the 0.79.0 incident mechanism). The 5 s lock_timeout per statement
  # is the bound we want; the scan itself takes no lock that blocks writes.
  #
  # The helper is copied from 20261107130100, not shared: the N-1 check runs
  # new migrations against the previous release's code, so a migration cannot
  # call a new `lib/` module.
  @doc false
  # Public for `NotesBodyColumnsUnreferencedLockTest`.
  def with_lock_timeout(repo, statements) do
    repo.checkout(
      fn ->
        repo.query!("SET lock_timeout = '5s'")

        try do
          Enum.each(statements, &run(repo, &1, @lock_retries))
        after
          repo.query!("RESET lock_timeout")
        end
      end,
      timeout: :infinity
    )
  end

  # A statement that hits its lock_timeout (55P03) is retried, so a busy
  # table does not crash boot. Only that statement: it changed nothing, and
  # starting over would repeat the VALIDATE scan.
  defp run(repo, statement, retries) do
    repo.query!(statement, [], timeout: :infinity)
  rescue
    e in Postgrex.Error ->
      if retries > 0 and match?(%{postgres: %{code: :lock_not_available}}, e),
        do: run(repo, statement, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end
end
