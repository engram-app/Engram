defmodule Engram.Repo.Migrations.ObanPendingNoteIdIndexExpand do
  use Ecto.Migration

  # phase/expand — new index only, no schema change.
  #
  # `Engram.Jobs.reject_pending/3` dedups every bulk enqueue keyed by
  # `args->>'note_id'` (EmbedNote, RebuildStaleNote, RefreshKeywordVectors).
  # Only EmbedNote had an index (oban_jobs_embed_note_note_id_index), so the
  # other two scanned oban_jobs once per 50 ids, and uncapped reconcile sweeps
  # queue thousands of them. One index for every worker: `worker` is a column
  # rather than part of the predicate, so a new note-keyed worker is covered
  # with no migration. Partial on unfinished states, so the 7 days of
  # completed jobs the pruner keeps are not indexed.
  #
  # The state list must stay a superset of both state sets in
  # `Engram.Jobs.pending_query/3` (guarded by jobs_test.exs).

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index("oban_jobs", ["(args->>'note_id')", "worker"],
             name: :oban_jobs_pending_note_id_index,
             where: "state IN ('scheduled','available','executing','retryable')",
             concurrently: true
           )
  end
end
