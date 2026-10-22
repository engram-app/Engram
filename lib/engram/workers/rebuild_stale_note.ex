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
  checks (`Rebuild.pace/0`) in every mode, and its Voyage tokens debit the
  bucket (`Rebuild.paced/1`).

  ## A halted pass resumes at once

  The reconcile sweep stamps every note it queues with its 30-minute
  backoff (#897), which only a successful embed clears. A job that runs
  while the pass is not `on` (halted, or switched off) finds its note
  current against the pins and completes without embedding, so the
  backoff would keep the note out of the sweep for up to 30 minutes after
  `on` returns. Such a job clears it (`release_halted/1`): the next sweep
  (the resume's `ReconcileEmbeddings.kick/0`, or the 5-minute cron) queues
  the note again. Nothing is paid twice: a rebuilt note is current and
  not selected, and a paid one is guarded by `notes.rebuild_paid_at`.
  """
  use Oban.Worker,
    queue: :rebuild,
    max_attempts: 5,
    unique: [period: 3600, keys: [:note_id], states: [:available, :scheduled]]

  import Ecto.Query

  alias Engram.Notes.Note
  alias Engram.Rebuild
  alias Engram.Repo
  alias Engram.Workers.{EmbedNote, ReconcileEmbeddings}

  @impl Oban.Worker
  def timeout(job), do: EmbedNote.timeout(job)

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"upgrade" => true}} = job) do
    with :ok <- Rebuild.pace(), do: Rebuild.paced(fn -> EmbedNote.perform(job) end)
  end

  def perform(%Oban.Job{args: args} = job) do
    with :ok <- Rebuild.gate(), :ok <- EmbedNote.perform(job) do
      if Rebuild.mode() == :on, do: :ok, else: release_halted(args)
    end
  end

  # Clears the sweep's backoff on a note still behind the BUILD's chunker,
  # which this job skipped because the pass is not `on`. Only that backoff
  # (stamped at most `ReconcileEmbeddings.backoff_seconds/0` out): a poison
  # cooldown (6 h) and a park until edited stay.
  defp release_halted(%{"note_id" => note_id, "user_id" => user_id}) do
    {chunker, _keyword} = Rebuild.build_versions()
    until = DateTime.add(DateTime.utc_now(), ReconcileEmbeddings.backoff_seconds(), :second)

    {:ok, _} =
      Repo.with_tenant(user_id, fn ->
        from(n in Note,
          where: n.kind == "note" and n.id == ^note_id,
          where: is_nil(n.chunker_version) or n.chunker_version < ^chunker,
          where: n.embed_retry_after <= ^until
        )
        |> Repo.update_all(set: [embed_retry_after: nil])
      end)

    :ok
  end

  # A legacy job without a tenant: nothing to release.
  defp release_halted(_args), do: :ok
end
