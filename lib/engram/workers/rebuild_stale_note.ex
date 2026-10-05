defmodule Engram.Workers.RebuildStaleNote do
  @moduledoc """
  Oban worker: a version rebuild (older chunker, or dense vectors from another
  embed model, on unchanged content) that `ReconcileEmbeddings` enqueues. The
  work is `EmbedNote`'s maintenance route (unmetered), and it keeps the note's
  dense vectors.

  A separate worker NAME, not a separate implementation: during a rolling
  deploy, nodes on the previous release share the `embed` queue, and their
  `EmbedNote` rebuilt stale-chunker notes METERED (a spent Free cap then went
  sparse-only and dropped the dense vectors for good). A worker they do not
  have makes them fail the job harmlessly; a new node retries it. See
  `docs/context/index-version-self-heal.md`.
  """
  use Oban.Worker,
    queue: :embed,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  alias Engram.Workers.EmbedNote

  @impl Oban.Worker
  def timeout(job), do: EmbedNote.timeout(job)

  @impl Oban.Worker
  def perform(%Oban.Job{} = job), do: EmbedNote.perform(job)
end
