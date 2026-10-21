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

  Its own `rebuild` queue (chunker v5 Task 16.2), so a pass never holds an
  `embed` slot a user's edit is waiting for. Every Voyage call here is
  `purpose: :maintenance`: never retried once it may have been billed (H6).
  While the v5 pass is `on`, each job first passes `Engram.Rebuild.gate/0`
  (the maintenance token bucket and the Qdrant optimizer backlog). A plan
  upgrade's re-embed (`upgrade: true`, `Engram.EmbedModels`) passes the same
  checks (`Rebuild.pace/0`) in every mode.
  """
  use Oban.Worker,
    queue: :rebuild,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  alias Engram.Rebuild
  alias Engram.Workers.EmbedNote

  @impl Oban.Worker
  def timeout(job), do: EmbedNote.timeout(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"upgrade" => true}} = job) do
    with :ok <- Rebuild.pace(), do: EmbedNote.perform(job)
  end

  def perform(%Oban.Job{} = job) do
    with :ok <- Rebuild.gate(), do: EmbedNote.perform(job)
  end
end
