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

  # The 10 min statement_timeout bounds the build; no lock_timeout, on one
  # pinned connection: see 20261105150100's `up/0`.
  def up do
    Engram.Repo.MigrationSession.with_session_settings(
      repo(),
      [{"statement_timeout", "10min"}],
      fn ->
        if invalid?("notes_folder_live"),
          do:
            repo().query!("DROP INDEX CONCURRENTLY IF EXISTS notes_folder_live", [],
              timeout: :infinity
            )

        repo().query!(
          """
          CREATE INDEX CONCURRENTLY IF NOT EXISTS notes_folder_live ON notes (vault_id, folder_id)
          INCLUDE (id, user_id) WHERE deleted_at IS NULL AND kind = 'note'
          """,
          [],
          timeout: :infinity
        )
      end
    )
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_live"
  end

  # A CONCURRENTLY build that fails or times out leaves an INVALID index;
  # a retry must drop it, never keep it, and never rebuild a good one
  # (20261103050000's pattern).
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
