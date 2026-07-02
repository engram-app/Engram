defmodule Engram.Workers.EmbedNoteBurstIndexTest do
  @moduledoc """
  `EmbedNote.existing_burst_start/1` runs on every content-changing upsert
  (`clamp: true` default) and filters `oban_jobs` by worker + `args->>'note_id'`
  + state. Without a supporting index that's a scan of the embed backlog —
  write latency degrades exactly when the queue is already stressed (positive
  feedback under a Voyage outage or an onboarding wave).

  Asserts the partial expression index exists and its predicate covers the
  same worker + state set the query uses (drift here silently reverts to
  scans — keep in sync with `existing_burst_start/1`).
  """
  use Engram.DataCase, async: true

  # Mirror of the state list in EmbedNote.existing_burst_start/1.
  @query_states ~w(scheduled available executing retryable)

  test "partial expression index backs the burst-start lookup" do
    %{rows: rows} =
      Repo.query!(
        "SELECT indexdef FROM pg_indexes WHERE tablename = 'oban_jobs' AND indexname = $1",
        ["oban_jobs_embed_note_note_id_index"]
      )

    assert [[indexdef]] = rows,
           "missing index oban_jobs_embed_note_note_id_index on oban_jobs"

    assert indexdef =~ "note_id",
           "index must be an expression index on (args ->> 'note_id')"

    assert indexdef =~ "Engram.Workers.EmbedNote"

    for state <- @query_states do
      assert indexdef =~ state,
             "index predicate must cover state '#{state}' (used by existing_burst_start/1)"
    end
  end
end
