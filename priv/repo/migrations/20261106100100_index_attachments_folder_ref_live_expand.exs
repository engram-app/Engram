defmodule Engram.Repo.Migrations.IndexAttachmentsFolderRefLiveExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  `attachments_folder_ref_live`: the live attachments of a folder row, for
  `folders_release_refs` (20261106100200). `attachments_folder_ref`
  (20261029000700) is not partial on purpose (the foreign key's `ON DELETE
  SET NULL` looks references up with no liveness predicate), so a lookup of
  the LIVE rows on it also reads every deleted attachment that ever sat in
  the folder (deleted rows keep their reference). On this one the trigger's
  cost is O(live references), which is 0 on a recursive delete (the content
  goes first).

  Write cost: `folder_ref_id` and `deleted_at` are already indexed, so no
  attachment write that was heap-only stops being so; one more entry on the
  writes that were not.

  Additive: the previous release ignores it. Rerun-safe with no operator
  step: an index a failed or timed-out CONCURRENTLY build left INVALID is
  dropped, then it is built IF NOT EXISTS. A 10 min `statement_timeout`
  bounds the build (no `lock_timeout`: see 20261105150100's `up/0`).
  """

  # The 10 min statement_timeout bounds the build; no lock_timeout, on one
  # pinned connection: see 20261105150100's `up/0`.
  def up do
    with_statement_timeout(fn ->
      if invalid?("attachments_folder_ref_live"),
        do:
          repo().query!("DROP INDEX CONCURRENTLY IF EXISTS attachments_folder_ref_live", [],
            timeout: :infinity
          )

      repo().query!(
        """
        CREATE INDEX CONCURRENTLY IF NOT EXISTS attachments_folder_ref_live ON attachments (vault_id, folder_ref_id)
        WHERE deleted_at IS NULL
        """,
        [],
        timeout: :infinity
      )
    end)
  end

  def down do
    execute "DROP INDEX CONCURRENTLY IF EXISTS attachments_folder_ref_live"
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
