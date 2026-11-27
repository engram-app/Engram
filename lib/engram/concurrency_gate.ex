defmodule Engram.ConcurrencyGate do
  @moduledoc """
  A counting semaphore process: at most `:limit` holders at once, optionally
  at most `:per_key` of them per key, with a FIFO wait queue. The one server
  behind `Engram.Sync.PageGate`, `Engram.MCP.ParseGate` and
  `Engram.Search.Gate`; each of those owns only its caller policy (degrade
  open, run in a task, refuse busy).

  The holder is the process that called `acquire/3`. It is monitored, so its
  slot comes back on `release/1`, on `cancel/1`, or when it dies, whichever is
  first: a crashed or killed holder cannot shrink capacity. A queued waiter is
  monitored too, so one that dies while waiting leaves the queue at once.

  Cost: acquire, release and holder death are O(1). Handing a freed slot to
  the next waiter is O(1) when there is no `:per_key` limit (PageGate,
  ParseGate: the head of the queue always fits, and PageGate's queue is
  unbounded). With a `:per_key` limit it scans for the oldest waiter whose
  key is under its cap, which is O(queue), so a per-key gate must also set
  `:max_waiting` (Search.Gate: 32). Withdrawing a waiter (its timeout or its
  death) is O(queue), and only happens to waiters.

  NOT re-entrant: one slot per holder pid. A second `acquire/3` from a pid
  that already holds a slot raises `ArgumentError` in the caller instead of
  silently double-counting its key. No caller nests acquires of the SAME
  gate. `Engram.Search` holds a `Search.Gate` slot inside its admission,
  which is safe only because they are two different gate processes.

  A gate restart forgets its holders: the new process starts empty while the
  old holders still run, so for a while up to twice the limit can run.
  Supervisor restart intensity bounds how often.

  Options for `start_link/1`: `:limit` (required), `:per_key`, `:max_waiting`,
  `:max_waiting_per_key` (each default `:infinity`), `:name` (`nil` starts an
  unregistered gate, addressed by pid, which is how tests isolate one).
  """
  use GenServer

  @type gate :: GenServer.server()

  def start_link(opts) do
    limits = %{
      limit: Keyword.fetch!(opts, :limit),
      per_key: Keyword.get(opts, :per_key, :infinity),
      max_waiting: Keyword.get(opts, :max_waiting, :infinity),
      max_waiting_per_key: Keyword.get(opts, :max_waiting_per_key, :infinity)
    }

    case Keyword.get(opts, :name) do
      nil -> GenServer.start_link(__MODULE__, limits)
      name -> GenServer.start_link(__MODULE__, limits, name: name)
    end
  end

  @doc """
  Take one slot for the calling process under `key`, waiting up to `timeout`
  ms. `:busy` when the queue is full, the wait ran out, or the gate is down.
  Raises `ArgumentError` if the caller already holds a slot of this gate.

  On a timeout the caller is still queued (and still alive), so it withdraws
  with a cast before returning: a grant that races the timeout would
  otherwise hand a slot to a caller that stopped listening, and capacity would
  leak one slot per timeout. Cast, not call: the gate may be down, and a
  second blocking call on the failure path is how a timeout becomes a hang.
  """
  @spec acquire(gate(), term(), timeout()) :: :ok | :busy
  def acquire(gate, key, timeout) do
    case call(gate, {:acquire, key}, timeout) do
      :reentrant -> raise ArgumentError, "#{inspect(self())} already holds a slot of this gate"
      status -> status
    end
  end

  defp call(gate, msg, timeout) do
    GenServer.call(gate, msg, timeout)
  catch
    :exit, _ ->
      cancel(gate)
      :busy
  end

  @doc """
  Take one slot for the calling process under `key` only if it is free right
  now and taking it still leaves `spare` slots free, with nobody queued:
  `:ok`, else `:busy`. Never waits and never queues, so it can only use
  capacity no waiting caller wants (a background sample beside live
  traffic). Same re-entrancy rule as `acquire/3`.
  """
  @spec try_acquire(gate(), term(), non_neg_integer()) :: :ok | :busy
  def try_acquire(gate, key, spare) do
    case call(gate, {:try_acquire, key, spare}, 1_000) do
      :reentrant -> raise ArgumentError, "#{inspect(self())} already holds a slot of this gate"
      status -> status
    end
  end

  @doc "Give back the calling process's slot."
  @spec release(gate()) :: :ok
  def release(gate), do: cast(gate, {:release, self()})

  @doc "Withdraw the calling process: its queue entry and any slot it holds."
  @spec cancel(gate()) :: :ok
  def cancel(gate), do: cast(gate, {:cancel, self()})

  defp cast(gate, msg) do
    GenServer.cast(gate, msg)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init(limits) do
    {:ok,
     Map.merge(limits, %{
       active: %{},
       counts: %{},
       queued: %{},
       waiters: %{},
       waiting: :queue.new()
     })}
  end

  @impl true
  def handle_call({:acquire, key}, {pid, _} = from, state) do
    cond do
      Map.has_key?(state.active, pid) or Map.has_key?(state.waiters, pid) ->
        {:reply, :reentrant, state}

      grantable?(state, key) ->
        {:reply, :ok, grant(state, pid, key)}

      full?(:queue.len(state.waiting), state.max_waiting) or
          full?(Map.get(state.queued, key, 0), state.max_waiting_per_key) ->
        {:reply, :busy, state}

      true ->
        {:noreply,
         %{
           state
           | waiting: :queue.in({from, key}, state.waiting),
             waiters: Map.put(state.waiters, pid, Process.monitor(pid)),
             queued: bump(state.queued, key, 1)
         }}
    end
  end

  def handle_call({:try_acquire, key, spare}, {pid, _}, state) do
    cond do
      Map.has_key?(state.active, pid) or Map.has_key?(state.waiters, pid) ->
        {:reply, :reentrant, state}

      :queue.is_empty(state.waiting) and map_size(state.active) + 1 + spare <= state.limit and
          grantable?(state, key) ->
        {:reply, :ok, grant(state, pid, key)}

      true ->
        {:reply, :busy, state}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, state |> drop(pid) |> pump()}

  # A caller that gave up waiting. Clears BOTH: the grant can race the
  # timeout, so the waiter may already have been promoted into `active`.
  def handle_cast({:cancel, pid}, state),
    do: {:noreply, state |> unqueue(pid) |> drop(pid) |> pump()}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, state |> unqueue(pid) |> drop(pid) |> pump()}

  defp grantable?(state, key),
    do:
      map_size(state.active) < state.limit and
        not full?(Map.get(state.counts, key, 0), state.per_key)

  defp full?(_n, :infinity), do: false
  defp full?(n, max), do: n >= max

  defp grant(state, pid, key) do
    ref = Process.monitor(pid)

    %{
      state
      | active: Map.put(state.active, pid, {ref, key}),
        counts: bump(state.counts, key, 1)
    }
  end

  defp drop(state, pid) do
    case Map.pop(state.active, pid) do
      {nil, _} ->
        state

      {{ref, key}, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | active: rest, counts: bump(state.counts, key, -1)}
    end
  end

  # O(1) for a pid that is not waiting (every holder): the scan only runs for
  # a waiter that timed out or died.
  defp unqueue(state, pid) do
    case Map.pop(state.waiters, pid) do
      {nil, _} ->
        state

      {ref, waiters} ->
        Process.demonitor(ref, [:flush])
        {gone, kept} = state.waiting |> :queue.to_list() |> Enum.split_with(&waiter?(&1, pid))
        queued = Enum.reduce(gone, state.queued, fn {_, key}, acc -> bump(acc, key, -1) end)
        %{state | waiting: :queue.from_list(kept), waiters: waiters, queued: queued}
    end
  end

  defp waiter?({{w, _}, _key}, pid), do: w == pid

  # Hand freed slots to waiters while there is room.
  defp pump(%{per_key: :infinity} = state) do
    with true <- map_size(state.active) < state.limit,
         {{:value, entry}, rest} <- :queue.out(state.waiting) do
      state |> hand_off(entry, rest) |> pump()
    else
      _ -> state
    end
  end

  # With a per-key limit: the oldest waiter whose key is under its cap. A
  # waiter of a key at its cap keeps its place; later waiters of other keys
  # go first, so one busy key cannot hold the whole gate behind it.
  defp pump(state) do
    if map_size(state.active) < state.limit do
      list = :queue.to_list(state.waiting)

      case Enum.find_index(list, fn {_, key} -> grantable?(state, key) end) do
        nil ->
          state

        i ->
          {entry, rest} = List.pop_at(list, i)
          state |> hand_off(entry, :queue.from_list(rest)) |> pump()
      end
    else
      state
    end
  end

  defp hand_off(state, {{pid, _} = from, key}, rest) do
    {ref, waiters} = Map.pop(state.waiters, pid)
    if ref, do: Process.demonitor(ref, [:flush])
    GenServer.reply(from, :ok)

    %{state | waiting: rest, waiters: waiters, queued: bump(state.queued, key, -1)}
    |> grant(pid, key)
  end

  defp bump(map, key, n) do
    case Map.get(map, key, 0) + n do
      0 -> Map.delete(map, key)
      v -> Map.put(map, key, v)
    end
  end
end
