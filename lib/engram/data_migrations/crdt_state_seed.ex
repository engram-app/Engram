defmodule Engram.DataMigrations.CrdtStateSeed do
  @moduledoc """
  Residue of the 2026-07-06 id-keying cutover, which NULLed every note's
  `crdt_state`: a note not written since binds to an empty doc. Each pass
  enqueues `BackfillCrdtState` for every live-vault pair holding a seedable
  note (`BackfillCrdtState.enqueue_missing/0`), unless a chain is still
  running. Done when none is left.

  A NULL-state note with an un-checkpointed tail in `crdt_update_log` is not
  this migration's work: seeding it would create a second Yjs lineage, and
  tail replay serves it. It neither keeps this open nor gets enqueued. A note
  whose content never decrypts does keep it open, at the cost of one vault's
  job per hour.
  """
  @behaviour Engram.DataMigration

  alias Engram.DataMigrations
  alias Engram.Workers.BackfillCrdtState

  @impl true
  def name, do: "crdt_state_seed"

  @impl true
  def version, do: 1

  @impl true
  def run_pass do
    # The worker has no `unique`: enqueueing while a chain runs would
    # duplicate it.
    cond do
      DataMigrations.jobs_in_flight?(BackfillCrdtState) -> :more
      BackfillCrdtState.enqueue_missing() == 0 -> :done
      true -> :more
    end
  end
end
