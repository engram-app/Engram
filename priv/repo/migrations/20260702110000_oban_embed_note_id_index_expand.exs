defmodule Engram.Repo.Migrations.ObanEmbedNoteIdIndexExpand do
  use Ecto.Migration

  # phase/expand — new index only, no schema change.
  #
  # EmbedNote.existing_burst_start/1 runs on every content-changing upsert
  # (debounce clamp) and filters oban_jobs by worker + args->>'note_id' +
  # state. Without this index the lookup scans the embed backlog, so write
  # latency degrades exactly when the queue is already stressed (Voyage
  # outage, onboarding wave). Partial + expression: only in-flight EmbedNote
  # rows are indexed, so steady-state maintenance cost is near zero.
  #
  # Keep the state list in sync with existing_burst_start/1 — the query's
  # `state IN (...)` must be a subset of the predicate or the planner
  # rejects the index (guarded by embed_note_burst_index_test.exs).

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index("oban_jobs", ["(args->>'note_id')"],
             name: :oban_jobs_embed_note_note_id_index,
             where:
               "worker = 'Engram.Workers.EmbedNote' AND state IN ('scheduled','available','executing','retryable')",
             concurrently: true
           )
  end
end
