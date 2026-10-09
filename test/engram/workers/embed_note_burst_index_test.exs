defmodule Engram.Workers.EmbedNoteBurstIndexTest do
  @moduledoc """
  The per-note EmbedNote lookup by worker + `args->>'note_id'` + state (once
  `existing_burst_start/1`, run on every content-changing upsert; the clamp
  now reads Oban's unique-check result instead). Without a supporting index
  such a lookup is a scan of the embed backlog.

  Asserts the partial expression index exists and its predicate covers that
  worker + state set (drift here silently reverts to scans).
  """
  use Engram.DataCase, async: true

  # The pending-or-running EmbedNote states.
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
             "index predicate must cover state '#{state}'"
    end
  end
end
