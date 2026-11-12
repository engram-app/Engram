# Shared summary line; see the file for why it is not in lib/.
Code.require_file("migration_log.exs", __DIR__)

defmodule Engram.Repo.Migrations.IndexNotesFolderNameLiveExpand do
  use Ecto.Migration

  alias Engram.Repo.Migrations.MigrationLog

  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `notes_folder_name_live`: a live note by its folder row and its own name
  (O(1) folder rename plan, S3 read switch, Engram#2523). The by-path lookup
  (`Engram.Notes.Location`) walks the folder chain on `folders_live_name`,
  then probes this index with `(vault_id, name_ci_hmac || folder_ref_id)`
  and filters the exact `name_hmac` on the rows it returns: at most the case
  variants of one name in one folder, never a scan of the folder's notes
  (`notes_folder_ref_live_id` would read every note in the folder).

  One concatenated key, not two columns: led by `(vault_id, folder_ref_id)`
  the index tied with `notes_folder_ref_live` for every by-folder read (the
  `folders_release_refs` trigger's update picked it, FolderRefReleaseTest),
  and led by `(vault_id, name_ci_hmac)` Postgres 18 skip-scanned it for a
  folder cascade's `folder_ref_id = ANY(...)` (NotesVaultScanTest). An
  expression serves only a query that names the same expression, so no
  by-folder read can pick it. `name_ci_hmac` is a fixed 32 bytes, so the
  concatenation is unambiguous. A root note (`folder_ref_id` NULL) has a
  NULL key and is not in it: S3 reads root notes by their stored path.

  Keyed on the casefolded name so the same key can later carry the S5
  per-folder name uniqueness. It is NOT unique here: names that differ only
  by case coexist today (`path_ci_hmac` is not unique either), so a unique
  build first needs the prod duplicate probe (#2523 risk R2) and a decision
  on those rows.

  Write cost: one more entry on a note write that changes the folder or the
  name (`folder_ref_id`, `name_ci_hmac` and the liveness columns change only
  on create, rename, move and delete); a content save leaves every key
  column as it was, so no save that was heap-only stops being so.

  Additive: the previous release ignores it. Rerun-safe with no operator
  step: an index a failed or timed-out CONCURRENTLY build left INVALID is
  dropped, then it is built IF NOT EXISTS. A 10 min `statement_timeout`
  bounds the build, on one pinned connection (20261106100000's pattern; no
  `lock_timeout`: see 20261105150100's `up/0`).
  """

  @index "notes_folder_name_live"

  def up do
    started = MigrationLog.now()

    with_statement_timeout(fn ->
      if invalid?(@index),
        do: repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{@index}", [], timeout: :infinity)

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS #{@index}
        ON notes (vault_id, (name_ci_hmac || uuid_send(folder_ref_id)))
        WHERE deleted_at IS NULL AND kind = 'note'
        """,
        [],
        timeout: :infinity
      )
    end)

    MigrationLog.indexes(repo(), "index_notes_folder_name_live", [@index], started)
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS #{@index}"
  end

  # A CONCURRENTLY build that fails or times out leaves an INVALID index; a
  # retry must drop it, never keep it, and never rebuild a good one.
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
  # statement can land on a different pooled connection, so a bare SET could
  # miss the build and leak into later migrations. Inlined, not shared: the
  # N-1 gate runs this file on the previous release's code, so a migration
  # calls no app module.
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
