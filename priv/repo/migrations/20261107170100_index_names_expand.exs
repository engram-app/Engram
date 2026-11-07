defmodule Engram.Repo.Migrations.IndexNamesExpand do
  use Ecto.Migration
  @disable_ddl_transaction true
  @disable_migration_lock true

  @moduledoc """
  O(1) folder rename plan, S2 expand (Engram#2523): the indexes the S3 read
  switch and the S5 old-client feed view need, built before anything reads
  them.

    * `notes_folder_name_ci` / `attachments_folder_name_ci`: a live row by
      folder and casefolded name (`(vault_id, folder_ref_id, name_ci_hmac)`).
      NOT unique: rows the previous release wrote carry no name yet, and drift
      rows may already collide. S3 builds the unique twin after a duplicate
      check. Partial on `name_ci_hmac IS NOT NULL`: an unnamed row has no
      place in it, and a lookup by folder alone (the `folders_release_refs`
      trigger) keeps planning on the `*_folder_ref_live` indexes.
    * `attachments_folder_ref_live_id`: a folder's live attachments in id
      order (`(vault_id, folder_ref_id, id)`, INCLUDE `user_id` for the RLS
      policy), so the old-client feed view can page them by id.
      `attachments_folder_ref_live` holds `id` only as an INCLUDE column, so
      it cannot. The notes twin is S1's (one definition).
    * `folders_vault_seq`: folders by structural change seq, empty until S5
      writes `folders.seq`.

  Write cost: one more entry per index on a non-HOT write of a live row
  (`notes_recent_index` already makes every content write non-HOT). The
  `NoteName` backfill's one update per row adds an entry to the two name
  indexes.

  Additive: the previous release ignores them. Rerun-safe with no operator
  step: an index a failed or timed-out CONCURRENTLY build left INVALID is
  dropped, then built IF NOT EXISTS, under a 10 min `statement_timeout`
  (20261106100000's pattern). Calls no app module (N-1 gate).
  """

  @indexes [
    {"notes_folder_name_ci",
     "ON notes (vault_id, folder_ref_id, name_ci_hmac) " <>
       "WHERE deleted_at IS NULL AND kind = 'note' AND name_ci_hmac IS NOT NULL"},
    {"attachments_folder_name_ci",
     "ON attachments (vault_id, folder_ref_id, name_ci_hmac) " <>
       "WHERE deleted_at IS NULL AND name_ci_hmac IS NOT NULL"},
    {"attachments_folder_ref_live_id",
     "ON attachments (vault_id, folder_ref_id, id) INCLUDE (user_id) WHERE deleted_at IS NULL"},
    {"folders_vault_seq", "ON folders (vault_id, seq) WHERE seq IS NOT NULL"}
  ]

  def up do
    with_statement_timeout(fn ->
      for {name, definition} <- @indexes do
        if invalid?(name),
          do: repo().query!("DROP INDEX CONCURRENTLY IF EXISTS #{name}", [], timeout: :infinity)

        repo().query!("CREATE INDEX CONCURRENTLY IF NOT EXISTS #{name} #{definition}", [],
          timeout: :infinity
        )
      end
    end)
  end

  def down do
    for {name, _} <- Enum.reverse(@indexes) do
      execute "DROP INDEX CONCURRENTLY IF EXISTS #{name}"
    end
  end

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

  # One pinned connection for the whole body (20261106100000's reason). Plain
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
