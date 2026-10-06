defmodule Engram.Workers.WarmCrdtHeads do
  @moduledoc """
  Hourly cron: re-warm NULL `notes.crdt_head` values. Every CRDT persist
  NULLs the head (`CrdtPersistence.update_v1/4`, plus a trigger on
  `crdt_state` writes), and only `BackfillCrdtHead` fills it back in, so
  without this the cold-reconcile head fast path degrades as notes are
  edited.

  A continuing self-heal, not an `Engram.DataMigration`: heads go NULL on
  every edit, so there is never a final "done". See
  `docs/context/data-migrations-ledger.md`.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3, unique: [period: 3000]

  alias Engram.DataMigrations
  alias Engram.Workers.BackfillCrdtHead

  # One discovery scan per user plus inserts; the rebuilds run in the
  # BackfillCrdtHead jobs it enqueues. Finite per #1496.
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(10)

  @impl Oban.Worker
  def perform(_job) do
    # BackfillCrdtHead has no `unique`: enqueueing while a chain runs would
    # duplicate it. The enqueue count is discarded.
    _ =
      unless DataMigrations.jobs_in_flight?(BackfillCrdtHead), do: BackfillCrdtHead.enqueue_all()

    :ok
  end
end
