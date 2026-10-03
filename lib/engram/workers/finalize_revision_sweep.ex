defmodule Engram.Workers.FinalizeRevisionSweep do
  @moduledoc """
  Hourly backstop for note-version outbox copies left without a job (#1710).

  `ContentCommit.after_commit/3` enqueues `FinalizeRevision` after the write's
  transaction commits. A process that dies in between leaves the copy in
  `note_revisions.pending_*` with nothing coming for it. This finds copies older
  than ten minutes (well past any live job's 5s schedule plus retries) and
  enqueues them again. Re-enqueueing is safe: `FinalizeRevision` takes a lock
  and re-reads, so a duplicate finds nothing to do. Copies parked as
  undecryptable (`finalize_failed_at`) are skipped, or each would come back
  every hour.

  Refuses rather than sweeping blind where RLS is enforced and no maintenance
  pool is configured, the same guard as `Engram.Workers.OrphanSweep`: the read
  would return zero rows, which looks identical to "nothing stranded".
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  import Ecto.Query

  alias Engram.Logger.Metadata
  alias Engram.Notes.Revision
  alias Engram.Repo
  alias Engram.Workers.FinalizeRevision

  require Logger

  @stale_after_seconds 600
  @batch 1_000

  # Finite so a hung job cannot pin a maintenance slot forever (#1496).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    if tenancy_unsafe?() do
      Logger.error(
        "finalize_revision_sweep refusing to run: RLS enforcement could not be ruled out " <>
          "and no maintenance pool is configured, so the read would return zero rows",
        Metadata.with_category(:error, :oban, [])
      )

      {:error, :tenancy_unsafe}
    else
      sweep()
    end
  end

  defp sweep do
    cutoff = DateTime.add(DateTime.utc_now(), -@stale_after_seconds, :second)

    pairs =
      Repo.maintenance().all(
        from(r in Revision,
          where:
            not is_nil(r.pending_ciphertext) and is_nil(r.finalize_failed_at) and
              r.updated_at < ^cutoff,
          # Oldest first, so a backlog over @batch drains in order. group_by,
          # not distinct: Postgres rejects ORDER BY on a column a DISTINCT
          # select leaves out.
          group_by: [r.note_id, r.user_id],
          order_by: min(r.updated_at),
          select: {r.note_id, r.user_id},
          limit: @batch
        ),
        skip_tenant_check: true
      )

    jobs =
      Enum.map(pairs, fn {note_id, user_id} -> FinalizeRevision.job(note_id, user_id) end)

    _ = if jobs != [], do: Oban.insert_all(jobs)
    :ok
  end

  defp tenancy_unsafe? do
    Repo.maintenance() == Repo and Engram.Repo.TenancyGuard.enforced?()
  end
end
