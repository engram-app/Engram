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
  alias Engram.ConcurrencyGate

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
    ConcurrencyGate.start_link(limit: limit, name: Keyword.get(opts, :name, __MODULE__))
  end

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

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
          ConcurrencyGate.release(gate)
        end

      # Timed out, or the gate is not running (self-host boots without it,
      # and tests may not start it). Either way the work still has to happen.
      # `acquire/3` has already withdrawn this caller from the queue, so the
      # next freed slot cannot be handed to a channel that stopped waiting.
      :busy ->
        Logger.warning("sync page gate unavailable or saturated, building page ungated",
          category: :sync
        )

        fun.()

      # This process already holds a slot (a nested page build). The shared
      # gate refuses re-entry with a raise; crashing the channel would strand
      # the sync, so the inner page runs ungated and, holding nothing,
      # releases nothing (the outer slot stays the outer call's).
      :nested ->
        Logger.warning("sync page gate re-entered, building nested page ungated",
          category: :sync
        )

        fun.()
    end
  end

  defp acquire(gate, timeout) do
    ConcurrencyGate.acquire(gate, nil, timeout)
  rescue
    ArgumentError -> :nested
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
end
