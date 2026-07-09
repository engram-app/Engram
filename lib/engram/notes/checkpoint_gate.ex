defmodule Engram.Notes.CheckpointGate do
  @moduledoc """
  Bounds concurrent SYNCHRONOUS unbind checkpoints so a reconnect storm cannot
  exhaust the DB connection pool.

  Each CRDT room runs a full checkpoint transaction on `terminate/2` (see
  `Engram.Notes.CrdtPersistence.unbind/3`), holding one `Engram.Repo`
  connection for the transaction's duration. When many rooms terminate at once
  (a client socket drop with `auto_exit: true` drops every one of that client's
  rooms simultaneously), N synchronous checkpoints fight the pool and the
  checkout queue times out with `DBConnection.ConnectionError` (the 2026-07-09
  pool-exhaustion incident).

  This gate caps inline checkpoints at `limit/0` (well under the pool). Up to the
  limit, `unbind/3` checkpoints synchronously (preserving materialization timing
  for the common single-note-close case); beyond it, `unbind/3` overflows to the
  durable, bounded `crdt_checkpoint` Oban queue. Loss-free either way: the
  tail-WAL is pruned only on a successful checkpoint, so a deferred checkpoint
  replays on the next room bind.

  ## Why a GenServer with monitors, not a bare counter

  An earlier version used a process-global `:atomics` counter released via
  `try/after`. That leaks: `after` does NOT run on a brutal `:kill` (a room
  whose checkpoint outlives the supervisor shutdown timeout during a deploy),
  so a leaked slot never decrements until node restart — eventually the counter
  pins at the limit and the synchronous fast path is silently, permanently
  defeated. Here `acquire/0` `Process.monitor/1`s the calling room process and
  releases its slot on `:DOWN`, so a killed room self-heals. Serializing
  check-and-increment through the GenServer also makes the limit exact (no
  transient over-count race).
  """
  use GenServer

  # Kept comfortably under POOL_SIZE (default 10) so inline checkpoints + the
  # crdt_checkpoint Oban lane (concurrency 3) + ungated room binds still leave
  # the pool headroom for REST/search/embed. Configurable via
  # `:checkpoint_inline_limit` so the test env can raise it out of the way
  # (many async tests spin real rooms that share this process-global gate).
  @default_limit 3

  # Client -----------------------------------------------------------------

  def start_link(_opts \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @spec limit() :: pos_integer()
  def limit do
    case Application.get_env(:engram, :checkpoint_inline_limit, @default_limit) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_limit
    end
  end

  @doc """
  Reserve an inline-checkpoint slot for the CALLING process. Returns `true` if a
  slot was granted (caller MUST `release/0` when done, via `try/after`), `false`
  if the gate is at capacity and the caller should overflow to the Oban queue.

  The slot is bound to the caller by a monitor: if the caller dies (even a
  brutal `:kill`) before `release/0`, the slot is reclaimed automatically.
  """
  @spec acquire() :: boolean()
  def acquire, do: GenServer.call(__MODULE__, :acquire)

  @spec release() :: :ok
  def release, do: GenServer.call(__MODULE__, :release)

  @doc "Test helper: drop all reservations and reset the counter."
  @spec reset() :: :ok
  def reset, do: GenServer.call(__MODULE__, :reset)

  # Server -----------------------------------------------------------------

  @impl true
  def init(:ok), do: {:ok, %{count: 0, refs: %{}}}

  @impl true
  def handle_call(:acquire, {pid, _tag}, %{count: count, refs: refs} = state) do
    if count < limit() do
      # One monitor per pid; a pid may hold >1 slot (only in tests — in prod one
      # room = one note = one slot). Track the held count so :DOWN releases all.
      refs =
        Map.update(refs, pid, {Process.monitor(pid), 1}, fn {ref, n} -> {ref, n + 1} end)

      {:reply, true, %{state | count: count + 1, refs: refs}}
    else
      {:reply, false, state}
    end
  end

  def handle_call(:release, {pid, _tag}, state), do: {:reply, :ok, release_one(state, pid)}

  def handle_call(:reset, _from, %{refs: refs}) do
    Enum.each(refs, fn {_pid, {ref, _n}} -> Process.demonitor(ref, [:flush]) end)
    {:reply, :ok, %{count: 0, refs: %{}}}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, %{count: count, refs: refs} = state) do
    case Map.pop(refs, pid) do
      {nil, _} -> {:noreply, state}
      {{_ref, n}, rest} -> {:noreply, %{state | count: max(count - n, 0), refs: rest}}
    end
  end

  defp release_one(%{count: count, refs: refs} = state, pid) do
    case Map.get(refs, pid) do
      nil ->
        state

      {ref, 1} ->
        Process.demonitor(ref, [:flush])
        %{state | count: max(count - 1, 0), refs: Map.delete(refs, pid)}

      {ref, n} ->
        %{state | count: max(count - 1, 0), refs: Map.put(refs, pid, {ref, n - 1})}
    end
  end
end
