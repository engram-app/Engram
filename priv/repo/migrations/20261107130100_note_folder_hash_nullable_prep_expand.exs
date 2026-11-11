defmodule Engram.Repo.Migrations.NoteFolderHashNullablePrepExpand do
  use Ecto.Migration

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  R9 schema prep: let a later release stop writing `notes.folder_hmac` on
  `kind = 'note'` rows (a note's folder is its `folder_ref_id`) while every
  release from this one on keeps working. Markers keep theirs: it is their
  path identity.

    * The column's NOT NULL is dropped by the migration before this one
      (20261107130000, kept alone so its squawk exemption covers one
      statement). A marker still needs the hash, by the check below.
    * `notes_kind_shape_v2_check` required `folder_hmac` on a note. It is
      replaced by `notes_kind_shape_v3_check`, identical but for that clause
      on notes. Added NOT VALID, then VALIDATE (SHARE UPDATE EXCLUSIVE: reads
      and writes continue during the scan), then the old one dropped. Every
      row and every write of the previous release has the hash, so the scan
      finds nothing.
    * `notes_set_folder_ref()` (both `notes_set_folder_ref` and
      `notes_set_folder_ref_on_restore` run it) derived the reference from
      the hash on every note INSERT and restore, so a write with no hash
      would lose the reference its writer set. With a NULL hash it now keeps
      the row's reference, released to NULL if it names a soft-deleted
      folder row (as `folder_ref_live_only` does; a restore does not fire
      that one). The previous release always writes the hash, so it sees no
      difference. Cost: none for a hash write; one `folders` primary-key
      probe for a NULL-hash write with a reference.

  No DDL transaction, so the NOT VALID add (ACCESS EXCLUSIVE, brief) commits
  before the VALIDATE scan. One pinned connection, so the `lock_timeout`
  reaches every statement and is reset after. Rerun-safe: a partial run is
  redone from the top. Calls no app module (N-1 gate).

  The checkout's own timeout bounds the whole block, statements included; left
  unset it inherits DBConnection's 15s, too short for the VALIDATE scan. The
  `lock_timeout` stays the real bound on lock waits, and a statement that hits
  it is retried twice.
  """

  @timeout_ms 120_000
  @lock_retries 2

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

  @set_ref_v2 """
  CREATE OR REPLACE FUNCTION notes_set_folder_ref() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
  BEGIN
    IF NEW.folder_hmac IS NULL THEN
      IF NEW.folder_ref_id IS NOT NULL AND EXISTS (
           SELECT 1 FROM public.folders f
           WHERE f.id = NEW.folder_ref_id AND f.deleted_at IS NOT NULL) THEN
        NEW.folder_ref_id := NULL;
      END IF;
      RETURN NEW;
    END IF;

    NEW.folder_ref_id := (
      SELECT f.id FROM public.folders f
      WHERE f.vault_id = NEW.vault_id
        AND f.full_path_hmac = NEW.folder_hmac
        AND f.deleted_at IS NULL
      LIMIT 1);
    RETURN NEW;
  END
  $$
  """

  @set_ref_v1 """
  CREATE OR REPLACE FUNCTION notes_set_folder_ref() RETURNS trigger
  LANGUAGE plpgsql SET search_path = '' AS $$
  BEGIN
    NEW.folder_ref_id := (
      SELECT f.id FROM public.folders f
      WHERE f.vault_id = NEW.vault_id
        AND f.full_path_hmac = NEW.folder_hmac
        AND f.deleted_at IS NULL
      LIMIT 1);
    RETURN NEW;
  END
  $$
  """

  def up do
    with_lock_timeout(repo(), [
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v3_check",
      @shape_v3,
      "ALTER TABLE notes VALIDATE CONSTRAINT notes_kind_shape_v3_check",
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v2_check",
      @set_ref_v2
    ])
  end

  # Back to the v2 check (NOT VALID: a note a later release wrote without a
  # hash stays readable) and the original function.
  def down do
    with_lock_timeout(repo(), [
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v2_check",
      @shape_v2,
      "ALTER TABLE notes DROP CONSTRAINT IF EXISTS notes_kind_shape_v3_check",
      @set_ref_v1
    ])
  end

  @doc false
  # Public for `NoteFolderHashPrepTimeoutTest`.
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
      timeout: @timeout_ms
    )
  end

  # Only the statement that failed is retried: one that failed changed nothing,
  # and starting over would repeat the VALIDATE scan.
  defp run(repo, statement, retries) do
    repo.query!(statement, [], timeout: @timeout_ms)
  rescue
    e in Postgrex.Error ->
      if retries > 0 and match?(%{postgres: %{code: :lock_not_available}}, e),
        do: run(repo, statement, retries - 1),
        else: reraise(e, __STACKTRACE__)
  end
end
