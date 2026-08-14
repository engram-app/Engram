defmodule Engram.Sync.PageGate do
  @moduledoc """
  Counting semaphore bounding how many full-content catch-up pages this node
  builds concurrently.

  The byte budget in `Engram.Notes.list_changes_by_seq/4` caps what ONE page may
  carry. This caps how many of those can be in flight at once, so a burst of
  first syncs degrades into a queue instead of stacking N pages of memory on an
  820 MB container. With a 4 MB budget and 8 slots the page working set stays
  around 32 MB (times the ~3 copies a frame makes on its way out) rather than
  scaling with however many people signed up this minute.

  ## Why it queues instead of rejecting

  The client's `walkOpLog` raises `OpLogFetchError` on a rejected fetch and
  aborts the entire walk. A "busy, come back later" reply would therefore turn
  load into a stalled first sync — the exact failure this whole workstream
  exists to remove. Waiters block; nobody is turned away.

  ## Why it degrades open

  If the wait budget expires, `with_slot/2` runs the work anyway and logs it.
  The gate smooths memory; it is not a correctness boundary. Raising would crash
  the channel and strand the sync, which is strictly worse than one unbounded
  page. A sustained stream of these in the logs means the limit is too low for
  the traffic, and that is a tuning signal, not an incident.

  Slots are released on normal completion AND on holder death (the holder is
  monitored), so a killed page-builder cannot shrink capacity until restart.
  """
  use GenServer
  require Logger

  @default_limit 8
  # Generous: a page is ~250 ms of work, so waiting out a full queue is normally
  # far under this. Hitting it means real saturation, not ordinary contention.
  @default_timeout 15_000

  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    limit = Keyword.get(opts, :limit) || configured_limit()
    GenServer.start_link(__MODULE__, limit, name: name)
  end

  @doc """
  Run `fun` holding one slot, waiting for a free one if necessary.

  Options: `:gate` (process name, for tests), `:timeout` (wait budget in ms).
  """
  def with_slot(fun, opts \\ []) do
    gate = Keyword.get(opts, :gate, __MODULE__)
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    case acquire(gate, timeout) do
      :ok ->
        try do
          fun.()
        after
          GenServer.cast(gate, {:release, self()})
        end

      :degraded ->
        fun.()
    end
  end

  defp acquire(gate, timeout) do
    GenServer.call(gate, :acquire, timeout)
  catch
    :exit, _ ->
      # Timed out, or the gate is not running (self-host boots without it, and
      # tests may not start it). Either way the work still has to happen.
      Logger.warning("sync page gate unavailable or saturated — building page ungated",
        category: :sync
      )

      :degraded
  end

  defp configured_limit do
    Application.get_env(:engram, :sync_page_concurrency, @default_limit)
  end

  @impl true
  def init(limit), do: {:ok, %{limit: limit, active: %{}, waiting: :queue.new()}}

  @impl true
  def handle_call(:acquire, {pid, _tag} = from, state) do
    if map_size(state.active) < state.limit do
      {:reply, :ok, grant(state, pid)}
    else
      {:noreply, %{state | waiting: :queue.in(from, state.waiting)}}
    end
  end

  @impl true
  def handle_cast({:release, pid}, state), do: {:noreply, state |> drop(pid) |> pump()}

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, state |> drop(pid) |> pump()}

  defp grant(state, pid) do
    ref = Process.monitor(pid)
    %{state | active: Map.put(state.active, pid, ref)}
  end

  defp drop(state, pid) do
    case Map.pop(state.active, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | active: rest}
    end
  end

  # Hand the freed slot to the next waiter. Skips waiters that died while queued
  # (their GenServer.call has no live receiver) so a dead waiter can't be granted
  # a slot nobody will ever release.
  defp pump(state) do
    case :queue.out(state.waiting) do
      {:empty, _} ->
        state

      {{:value, {pid, _tag} = from}, rest} ->
        state = %{state | waiting: rest}

        if Process.alive?(pid) do
          GenServer.reply(from, :ok)
          grant(state, pid)
        else
          pump(state)
        end
    end
  end
end
