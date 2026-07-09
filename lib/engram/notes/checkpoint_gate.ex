defmodule Engram.Notes.CheckpointGate do
  @moduledoc """
  Bounds concurrent SYNCHRONOUS unbind checkpoints so a reconnect storm cannot
  exhaust the DB connection pool.

  Each CRDT room runs a full checkpoint transaction on `terminate/2` (see
  `Engram.Notes.CrdtPersistence.unbind/3`), holding one `Engram.Repo`
  connection for the transaction's duration. When many rooms terminate at once
  (a client socket drop with `auto_exit: true` drops every one of that client's
  rooms simultaneously), N synchronous checkpoints fight the 10-connection pool
  and the checkout queue times out with `DBConnection.ConnectionError` (the
  2026-07-09 pool-exhaustion incident).

  This gate caps inline checkpoints at `@limit` (well under the pool). Up to the
  limit, `unbind/3` checkpoints synchronously as before (preserving materialization
  timing for the common single-note-close case). Beyond the limit, `unbind/3`
  overflows to the durable, bounded `crdt_checkpoint` Oban queue instead of piling
  onto the pool. Loss-free either way: the tail-WAL is pruned only on a successful
  checkpoint, so a deferred checkpoint replays on the next room bind.

  Backed by a single `:atomics` counter in `:persistent_term`, initialized once
  at boot by `Engram.Application`.
  """

  # Under POOL_SIZE (default 10), leaving headroom for REST/search/Oban queries
  # that share the same pool. The overflow path (Oban queue at concurrency 3)
  # absorbs anything past this.
  @limit 5

  @spec init() :: :ok
  def init, do: :persistent_term.put(__MODULE__, :atomics.new(1, signed: true))

  @spec limit() :: pos_integer()
  def limit, do: @limit

  @doc """
  Try to reserve an inline-checkpoint slot. Returns `true` if a slot was granted
  (caller MUST `release/0` when done, via `try/after`), `false` if the gate is at
  capacity and the caller should overflow to the Oban queue.
  """
  @spec acquire() :: boolean()
  def acquire do
    ref = ref()

    if :atomics.add_get(ref, 1, 1) <= @limit do
      true
    else
      # Over capacity: roll back our increment so refusals do not leak slots.
      :atomics.sub(ref, 1, 1)
      false
    end
  end

  @spec release() :: :ok
  def release, do: :atomics.sub(ref(), 1, 1)

  defp ref, do: :persistent_term.get(__MODULE__)
end
