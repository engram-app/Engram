defmodule Engram.Repo.Migrations.DropNotesFolderNameLiveContract do
  use Ecto.Migration

  # phase/contract: drops `notes_folder_name_live` (20261112100000), the S3
  # by-name index of the O(1) folder rename plan (Engram#2523). No code has
  # named its expression since #2589 (release 0.84.0): the by-name lookup
  # probes `notes_name_key_live`. Prod still scanned it (0.87.0: 9,757 scans)
  # because its leading `vault_id` and its `deleted_at IS NULL AND kind =
  # 'note'` predicate make it a generic vault-scoped live-note index for any
  # read with no user qual (the maintenance pool). Those reads move to the
  # other vault-leading live indexes (`notes_folder_ref_live`, ...), pinned
  # by NotesVaultLivePlanTest. Every note write that changes the folder or
  # the name still paid for one entry in it; this ends that. (First written
  # as #2628, folded into release J.)
  #
  # Not dropped here: `folders_moved_live` (same file, read by every
  # by-path lookup) and every `path_*` / `folder_*` column, which writers
  # still write and read as the stored-path truth.
  #
  # DROP INDEX CONCURRENTLY cannot run in a transaction. One pinned
  # connection so the statement_timeout lands on the dropping session: a
  # boot that meets a long transaction on `notes` fails after 60 s instead
  # of hanging, and the next boot reruns IF EXISTS (a cancelled concurrent
  # drop leaves the index INVALID, which the rerun drops).

  @disable_ddl_transaction true
  @disable_migration_lock true

  @index_spec "ON notes (vault_id, (name_ci_hmac || uuid_send(folder_ref_id))) " <>
                "WHERE deleted_at IS NULL AND kind = 'note'"

  def up, do: bounded("DROP INDEX CONCURRENTLY IF EXISTS notes_folder_name_live")

  def down,
    do: bounded("CREATE INDEX CONCURRENTLY IF NOT EXISTS notes_folder_name_live #{@index_spec}")

  defp bounded(sql) do
    repo().checkout(
      fn ->
        repo().query!("SET statement_timeout = '60s'")

        try do
          repo().query!(sql, [], timeout: 65_000)
        after
          repo().query!("RESET statement_timeout")
        end
      end,
      timeout: 70_000
    )
  end
end
