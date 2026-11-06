defmodule Engram.Repo.Migrations.IndexNotesFolderRefLiveExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_ref_live`: the covering index `Engram.Search.NoteFilter`'s
  folder filter needs before it can read `folder_ref_id` instead of the
  stored folder key (`folder_ref_id = ANY(...)` and its complement, the
  `:exclude` path), as index-only scans over a vault's live notes. The
  `folder_ref_id` twin of `notes_folder_live` (20261105150200), INCLUDE
  `(id, user_id)` for the same reason (`user_id`: the RLS policy reads it).
  No reader uses it yet: this is the expand step. `folders_release_refs`
  (20261106100200) looks up a folder row's live notes on it.

  `notes_folder_ref (vault_id, folder_ref_id)` (20261029000600) stays: it is
  not partial on purpose (the foreign key's `ON DELETE SET NULL` action looks
  references up with no liveness predicate), so a lookup of LIVE notes on it
  also reads every trashed note and rename tombstone that names the folder,
  and it is not covering, so a filter on it reads one heap block per match.

  Write cost: one more entry on a non-HOT note write; `folder_ref_id` is
  already indexed (and `notes_recent_index` makes every content write
  non-HOT), so no write that was heap-only stops being so.

  Additive: the previous release ignores it. Rerun-safe with no operator
  step: an index a failed or timed-out CONCURRENTLY build left INVALID is
  dropped, then it is built IF NOT EXISTS. A 10 min `statement_timeout`
  bounds the build (no `lock_timeout`: see 20261105150100's `up/0`).
  """

  # The 10 min statement_timeout bounds the build; no lock_timeout, on one
  # pinned connection: see 20261105150100's `up/0`.
  def up do
    with_statement_timeout(fn ->
      if invalid?("notes_folder_ref_live"),
        do:
          repo().query!("DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_live", [],
            timeout: :infinity
          )

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS notes_folder_ref_live ON notes (vault_id, folder_ref_id)
        INCLUDE (id, user_id) WHERE deleted_at IS NULL AND kind = 'note'
        """,
        [],
        timeout: :infinity
      )
    end)
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS notes_folder_ref_live"
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

  # One pinned connection for the whole body: with no DDL transaction each
  # `execute` can land on a different pooled connection (the release
  # migrator's pool is 2), so a bare SET could miss the build and leak into
  # later migrations. Inlined, not shared: the N-1 gate runs this file on
  # the previous release's code, so a migration calls no app module. Plain
  # SQL, no bind params, so squawk can parse what it logs.
  defp with_statement_timeout(fun) do
    repo().checkout(fn ->
      repo().query!("SET statement_timeout = '10min'")

      try do
        fun.()
      after
        repo().query!("RESET statement_timeout")
      end
    end)
  end
end
