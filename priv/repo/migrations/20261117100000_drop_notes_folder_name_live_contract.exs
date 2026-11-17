defmodule Engram.Repo.Migrations.DropNotesFolderNameLiveContract do
  use Ecto.Migration

  # phase/contract: drops `notes_folder_name_live` (20261112100000), the S3
  # by-name index of the O(1) folder rename plan (Engram#2523). It has had
  # no reader since #2589 (release 0.84.0): the by-name lookup probes
  # `notes_name_key_live` on the stored `name_key` instead, and an
  # expression index serves only a query that names the same expression,
  # which nothing in lib/ does. The rollback floor is 0.87.0, so no release
  # a deploy can run beside this one reads it. Every note write that changes
  # the folder or the name still pays for one entry in it; this ends that.
  #
  # Not dropped here: `folders_moved_live` (same file, read by every
  # by-path lookup) and every `path_*` / `folder_*` column, which S5 still
  # writes and reads as the stored-path truth (see the PR body).
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
