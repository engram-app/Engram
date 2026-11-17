defmodule Engram.ConcurrencyGate do
  @moduledoc """
  A counting semaphore process: at most `:limit` holders at once, optionally
  at most `:per_key` of them per key, with a bounded FIFO wait queue. The one
  server behind `Engram.Sync.PageGate`, `Engram.MCP.ParseGate` and
  `Engram.Search.Gate`; each of those owns only its caller policy (degrade
  open, run in a task, refuse busy).

  The holder is the process that called `acquire/3`. It is monitored, so its
  slot comes back on `release/1`, on `cancel/1`, or when it dies, whichever is
  first: a crashed or killed holder cannot shrink capacity. A queued waiter is
  monitored too, so one that dies while waiting leaves the queue at once.

  Every operation costs O(1) except handing a freed slot to the next waiter,
  which scans the queue for the first waiter whose key is under `:per_key`.
  The queue is bounded by `:max_waiting` (and `:max_waiting_per_key`), so that
  scan is bounded too. A `:busy` reply (queue full) is immediate.

  NOT re-entrant: one slot per holder pid. Acquiring twice from the same
  process would overwrite its own entry. No caller nests.

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

  On a timeout the caller is still queued (and still alive), so it withdraws
  with a cast before returning: a grant that races the timeout would
  otherwise hand a slot to a caller that stopped listening, and capacity would
  leak one slot per timeout. Cast, not call: the gate may be down, and a
  second blocking call on the failure path is how a timeout becomes a hang.
  """
  @spec acquire(gate(), term(), timeout()) :: :ok | :busy
  def acquire(gate, key, timeout) do
    GenServer.call(gate, {:acquire, key}, timeout)
  catch
    :exit, _ ->
      cancel(gate)
      :busy
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
  def init(limits),
    do: {:ok, Map.merge(limits, %{active: %{}, counts: %{}, queued: %{}, waiting: :queue.new()})}

  @impl true
  def handle_call({:acquire, key}, {pid, _} = from, state) do
    cond do
      grantable?(state, key) ->
        {:reply, :ok, grant(state, pid, key)}

      full?(:queue.len(state.waiting), state.max_waiting) or
          full?(Map.get(state.queued, key, 0), state.max_waiting_per_key) ->
        {:reply, :busy, state}

      true ->
        entry = {from, key, Process.monitor(pid)}

        {:noreply,
         %{
           state
           | waiting: :queue.in(entry, state.waiting),
             queued: bump(state.queued, key, 1)
         }}
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

  defp unqueue(state, pid) do
    {gone, kept} =
      state.waiting |> :queue.to_list() |> Enum.split_with(fn {{w, _}, _, _} -> w == pid end)

    Enum.reduce(gone, %{state | waiting: :queue.from_list(kept)}, fn {_, key, ref}, acc ->
      Process.demonitor(ref, [:flush])
      %{acc | queued: bump(acc.queued, key, -1)}
    end)
  end

  # Hand freed slots to the oldest waiters whose key is under `:per_key`. A
  # waiter of a key at its cap keeps its place; later waiters of other keys
  # go first, so one busy key cannot hold the whole gate behind it.
  defp pump(state) do
    if map_size(state.active) < state.limit do
      list = :queue.to_list(state.waiting)

      case Enum.find_index(list, fn {_, key, _} -> grantable?(state, key) end) do
        nil ->
          state

        i ->
          {{{pid, _} = from, key, ref}, rest} = List.pop_at(list, i)
          Process.demonitor(ref, [:flush])
          GenServer.reply(from, :ok)

          %{state | waiting: :queue.from_list(rest), queued: bump(state.queued, key, -1)}
          |> grant(pid, key)
          |> pump()
      end
    else
      state
    end
  end

  defp bump(map, key, n) do
    case Map.get(map, key, 0) + n do
      0 -> Map.delete(map, key)
      v -> Map.put(map, key, v)
    end
  end
end
