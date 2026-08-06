defmodule Engram.Repo.Migrations.IndexRewriteNoteLinksOldBasenameHmacExpand do
  use Ecto.Migration

  # phase/expand — new index only, no schema change.
  #
  # ExtractNoteLinks.recent_rename_job_args/3 (#648 lever 2, bind-time rename
  # repair) runs whenever a freshly-extracted edge lands DANGLING — an
  # ordinary authoring pattern (link-before-target-exists), not a rare path —
  # and filters oban_jobs by worker + args->>'old_basename_hmac' (any state,
  # completed included, per the repair evidence contract). Without this index
  # the lookup scans the RewriteNoteLinks backlog on every such save. Mirrors
  # 20260702110000_oban_embed_note_id_index_expand.exs: partial + expression,
  # so steady-state maintenance cost stays near the RewriteNoteLinks row count
  # (self-bounded by the 7-day Oban Pruner), not the whole oban_jobs table.
  #
  # No state predicate here (unlike the EmbedNote index): the repair query
  # deliberately matches ANY state — the durable evidence for a rename can be
  # a long-completed job row — so only `worker` narrows the partial index.

  @disable_ddl_transaction true
  @disable_migration_lock true

  def change do
    create index("oban_jobs", ["(args->>'old_basename_hmac')"],
             name: :oban_jobs_rewrite_note_links_old_basename_hmac_index,
             where: "worker = 'Engram.Workers.RewriteNoteLinks'",
             concurrently: true
           )
  end
end
