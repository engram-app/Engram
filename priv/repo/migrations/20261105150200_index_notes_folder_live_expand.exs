defmodule Engram.Repo.Migrations.IndexNotesFolderLiveExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_live`: a folder-subtree filter (`Engram.Search.NoteFilter`,
  `folder_id = ANY(...)`) and its complement (`NOT ...`, the `:exclude`
  path) as index-only scans over a vault's live notes. INCLUDE `(id,
  user_id)` (`user_id` because the RLS policy reads it).

  `notes_folder (vault_id, folder_id)` already serves the lookup, but it is
  not partial and not covering: staging EXPLAIN 2026-11-05 (1,518-note
  vault) read one heap block per matching note (810 matches, 733 blocks),
  and the complement cannot use it at all, so it read the heap of every live
  note (7 to 13 ms per 1k). Kept: the folder-marker lookup needs it.

  Write cost: one more entry on a non-HOT note write; `notes_recent_index`
  already makes every content write non-HOT.

  Additive: the previous release ignores it. Rerun-safe with no operator
  step: an index a failed or timed-out CONCURRENTLY build left INVALID is
  dropped, then it is built IF NOT EXISTS. A 10 min
  `statement_timeout` bounds the build (no `lock_timeout`: see `up/0`).
  """

  def up do
    invalid? = invalid?("notes_folder_live")
    # statement_timeout bounds the whole build (the scans and the wait for
    # older snapshots), so a stuck build fails the deploy and the next boot
    # retries it, instead of hanging. No lock_timeout, deliberately: a
    # CONCURRENTLY build waits out older transactions through lock waits, so
    # a short lock_timeout fails it on any transaction open longer than that
    # and leaves an INVALID index (why `Engram.Release.migrator_config/1`
    # keeps the app Repo's lock_timeout off the migrator).
    execute "SET statement_timeout = '10min'"

    if invalid?, do: execute("DROP INDEX CONCURRENTLY IF EXISTS notes_folder_live")

    execute """
    CREATE INDEX CONCURRENTLY IF NOT EXISTS notes_folder_live ON notes (vault_id, folder_id)
    INCLUDE (id, user_id) WHERE deleted_at IS NULL AND kind = 'note'
    """

    execute "RESET statement_timeout"
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_live"
  end

  # A CONCURRENTLY build that fails or times out leaves an INVALID index;
  # a retry must drop it, never keep it, and never rebuild a good one
  # (20261103050000's pattern). Read before any command runs: Ecto buffers
  # the `execute`s below.
  defp invalid?(name) do
    %{rows: rows} =
      repo().query!(
        "SELECT 1 FROM pg_index i JOIN pg_class c ON c.oid = i.indexrelid " <>
          "WHERE c.relname = $1 AND NOT i.indisvalid",
        [name],
        log: false
      )

    rows != []
  end
end
