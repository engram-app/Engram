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

  # Derived from the DB pool, never hardcoded. Every page build checks out a
  # connection for its read, so N slots is N connections unavailable to
  # checkpoints, other channels and the seq feed. A flat number also goes stale
  # silently the moment POOL_SIZE moves (it went 10 -> 15 without this file
  # knowing), which is exactly the class of bug a derived value cannot have.
  #
  # A third: enough to overlap real work, not enough to monopolise the pool. A
  # page is ~250 ms, so even 5 slots clears ~20 vaults/second. (The sibling this
  # used to cite, crdt_channel.batch_concurrency, went with crdt_create_batch.)
  @pool_divisor 3
  @min_limit 2

  # Generous: a page is ~250 ms of work, so waiting out a full queue is normally
  # far under this. Hitting it means real saturation, not ordinary contention.
  @default_timeout 15_000

  @doc """
  Start the gate. `name: nil` starts it unregistered, addressed by pid — which
  is how tests get an isolated instance without either minting a runtime atom
  per test or colliding with the app-supervised one.
  """
  def start_link(opts) do
    limit = Keyword.get(opts, :limit) || configured_limit()

    case Keyword.fetch(opts, :name) do
      {:ok, nil} -> GenServer.start_link(__MODULE__, limit)
      {:ok, name} -> GenServer.start_link(__MODULE__, limit, name: name)
      :error -> GenServer.start_link(__MODULE__, limit, name: __MODULE__)
    end
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
      #
      # WITHDRAW FIRST. A timed-out caller is still sitting in the waiting queue,
      # and it is still alive — it is a channel process that merely gave up
      # waiting. Without this, the next free slot gets handed to it, the reply
      # goes nowhere, and the slot is held until that channel dies. Under exactly
      # the sustained load this gate exists for, capacity leaks away one slot at
      # a time and every later page runs ungated while the logs say nothing,
      # because degrading open is the designed behaviour. Protection that can
      # vanish without a signal is worse than none.
      #
      # Cast, not call: the gate may be down, and a second blocking call on the
      # failure path is how a timeout becomes a hang.
      catch_exit_cast(gate, {:cancel, self()})

      Logger.warning("sync page gate unavailable or saturated — building page ungated",
        category: :sync
      )

      :degraded
  end

  defp catch_exit_cast(gate, msg) do
    GenServer.cast(gate, msg)
  catch
    :exit, _ -> :ok
  end

  @doc """
  Slots this node allows, derived from the configured Ecto pool unless
  overridden by `:sync_page_concurrency`. Public so a test can pin the pool
  coupling — a plausible-looking hardcoded number is what this replaced.
  """
  def configured_limit do
    case Application.get_env(:engram, :sync_page_concurrency) do
      n when is_integer(n) and n > 0 ->
        n

      _ ->
        pool = Keyword.get(Application.get_env(:engram, Engram.Repo, []), :pool_size, 10)
        max(@min_limit, div(pool, @pool_divisor))
    end
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

  # A caller that gave up waiting. Must clear BOTH queues: the grant can race
  # the timeout, so by the time this arrives the waiter may already have been
  # promoted into `active` and be holding a slot nobody will ever release.
  @impl true
  def handle_cast({:cancel, pid}, state) do
    waiting = :queue.filter(fn {waiter, _tag} -> waiter != pid end, state.waiting)
    {:noreply, %{state | waiting: waiting} |> drop(pid) |> pump()}
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state),
    do: {:noreply, state |> drop(pid) |> pump()}

  # NOT re-entrant: `active` is keyed by pid, so the same process acquiring
  # twice would overwrite its own monitor ref (leaking the first) and count as
  # one slot, over-admitting by one. There is a single call site and it does not
  # nest; if that ever changes, this needs a per-pid depth count rather than a
  # bare map.
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
