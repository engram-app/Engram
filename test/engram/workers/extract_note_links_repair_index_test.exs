defmodule Engram.Workers.ExtractNoteLinksRepairIndexTest do
  @moduledoc """
  `ExtractNoteLinks.recent_rename_job_args/3` (#648 lever 2, bind-time rename
  repair) runs whenever a freshly-extracted edge lands DANGLING — an ordinary
  authoring pattern (link-before-target-exists), not a rare path — and
  filters `oban_jobs` by worker + `args->>'old_basename_hmac'` (any state,
  completed included — the repair evidence contract). Without a supporting
  index that's a scan of the whole RewriteNoteLinks backlog on every such
  save.

  Asserts the partial expression index exists and its predicate covers the
  worker the query filters on (drift here silently reverts to scans — keep in
  sync with `recent_rename_job_args/3`). Mirrors
  `embed_note_burst_index_test.exs`.
  """
  use Engram.DataCase, async: true

  test "partial expression index backs the rename-repair lookup" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'oban_jobs' AND indexname = $1",
        ["oban_jobs_rewrite_note_links_old_basename_hmac_index"]
      )

    assert [[indexdef]] = rows,
           "missing index oban_jobs_rewrite_note_links_old_basename_hmac_index on oban_jobs"

    assert indexdef =~ "old_basename_hmac",
           "index must be an expression index on (args ->> 'old_basename_hmac')"

    assert indexdef =~ "Engram.Workers.RewriteNoteLinks"
  end
end
