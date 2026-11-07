defmodule Engram.Workers.RepathNoteIndex do
  @moduledoc """
  Retired (R3a): a rename or move makes ZERO Qdrant writes. A point's payload
  is the note's identity (`u`, `v`, `n`), which a rename does not change, and
  the keyword vectors' stale path prefix is accepted until the once-only
  rebuild strips it. Nothing enqueues this worker any more.

  The module stays so a job an older node queued during a rolling deploy
  still runs here, and succeeds doing nothing, instead of failing on an
  unknown worker.
  """

  # ponytail: no-op shim for in-flight jobs; delete in R3b
  # (with its `Engram.Jobs` unique entry).
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: Engram.Jobs.unique(__MODULE__)

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
