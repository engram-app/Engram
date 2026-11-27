defmodule Engram.Search.Gate do
  @moduledoc """
  Bounds how many searches run at once on this node: at most `:per_user` per
  user and `:limit` in total (`config :engram, :search_gate`).

  Why: Qdrant runs about 4 searches at a time and queues the rest. One MCP
  client firing ~40 parallel hybrid searches a minute pushed every user's
  median search from a few ms to hundreds, and some to Qdrant's server
  timeout. This queue lives in the BEAM, is fair per user, and fails fast.

  `run/2` holds a slot of the `Engram.ConcurrencyGate` server in the CALLING
  process for ONE Qdrant request (`Engram.Search` wraps each of a search's
  Qdrant calls, never its query embed or Postgres reads, so a slow embedder
  costs no slot). The slot is released when `fun` returns, raises or exits,
  and when the caller dies (the gate monitors it). A caller that gets no
  slot within `:acquire_timeout` ms, or finds the queue full (`:max_waiting`
  in total, `:max_waiting_per_user` for its user), gets `{:error, :search_busy}`
  without running `fun`.

  The wait is per Qdrant request, not per search: a search makes at most 3
  (its first round, one widen round, one payload fallback retrieve), so it
  can wait up to 3 x `:acquire_timeout` (7.5 s) in the worst case, and a busy
  refusal in a later request comes after its embed was paid for (never its
  budget token: `Search.search/4` charges only a search that was not busy).
  Accepted: bounded, and it surfaces as an error, never a partial page.

  A client that hangs up does not stop its search: Bandit keeps running the
  request process, so an abandoned type-ahead search keeps its slot until
  its Qdrant request ends, at most the search receive timeout (5 s; Qdrant
  gives up at 4 s).

  If the gate process is down (restarting), every search is refused busy
  until it is back (fail closed). A restarted gate starts empty while the old
  holders finish, so for a moment up to twice the limit can run.

  The cap is PER NODE (prod runs 2 web nodes and 1 worker), so the cluster
  allows up to nodes x `:limit`. Sized for Qdrant's pool, that over-admits a
  little when several nodes are busy at once; a cluster-wide count would need
  a cross-node round trip per search, which costs more than it saves here.

  Each `run/2` and `admit/2` emits `[:engram, :search, :gate]` with
  `%{wait: native}` (time to a slot or to the refusal) and `%{outcome: :ok |
  :busy, gate: :qdrant | :admission, upstream: :none}` (`gate: :shadow` from
  `try_run/1`: a sample, never a live search); a `pool_busy/2`
  refusal emits it with `gate: :pool`, its `upstream` and `wait: 0`. No user
  id.

  Around all of that, `admit/2` bounds WHOLE searches per user on a second
  gate (embed included), and `pool_busy/2` turns a saturated Finch pool on
  the query embed or a Qdrant request into the same busy error. A hybrid
  search whose embed hits a busy pool still degrades to keyword-only, like
  any embed failure; a vector-only one is refused busy.

  Test seam: `ServiceConfig.put_override(:search_gate, gate: pid, ...)` points
  a test's searches at its own unregistered gate (`admission_gate: pid` for
  the admission one).
  """

  alias Engram.ConcurrencyGate
  alias Engram.Logger.Metadata
  alias Engram.ServiceConfig

  require Logger

  @event [:engram, :search, :gate]
  @admission Engram.Search.Admission

  # Finch RAISES (it does not return an error) when no pooled connection
  # frees up within `:pool_timeout`: `Finch.HTTP1.Pool.request/6` reraises
  # NimblePool's checkout exit as a RuntimeError with this message. Matched
  # by prefix because that message is the only thing identifying it.
  @pool_busy "Finch was unable to provide a connection"

  @doc """
  `kind: :qdrant` (default) is the per-request Qdrant slot gate; `kind:
  :admission` is the per-user gate around whole searches (`admit/2`).
  """
  def child_spec(opts) do
    kind = Keyword.get(opts, :kind, :qdrant)
    %{id: {__MODULE__, kind}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "Start a gate from `config :engram, :search_gate`; `opts` win."
  def start_link(opts \\ []) do
    config = Keyword.merge(Application.get_env(:engram, :search_gate, []), opts)

    case Keyword.get(config, :kind, :qdrant) do
      :qdrant ->
        ConcurrencyGate.start_link(
          limit: Keyword.fetch!(config, :limit),
          per_key: Keyword.fetch!(config, :per_user),
          max_waiting: Keyword.fetch!(config, :max_waiting),
          max_waiting_per_key: Keyword.fetch!(config, :max_waiting_per_user),
          name: Keyword.get(config, :name, __MODULE__)
        )

      :admission ->
        ConcurrencyGate.start_link(
          limit: Keyword.fetch!(config, :admission_limit),
          per_key: Keyword.fetch!(config, :admission_per_user),
          max_waiting: Keyword.fetch!(config, :admission_max_waiting),
          max_waiting_per_key: Keyword.fetch!(config, :admission_max_waiting_per_user),
          name: Keyword.get(config, :name, @admission)
        )
    end
  end

  @doc "Run ONE Qdrant request of a search in a slot (see the moduledoc)."
  @spec run(term(), (-> result)) :: result | {:error, :search_busy} when result: var
  def run(user_id, fun), do: through(:qdrant, :gate, __MODULE__, user_id, fun)

  @doc """
  Run `fun` in a slot of the same per-request gate, but only if one is free
  RIGHT NOW with one more left over and nobody queued; else
  `{:error, :search_busy}` at once. For background samples beside live
  searches (`Engram.KeywordStore.Shadow`): it never waits, never queues
  ahead of a live search, and holds its own key (`:keyword_shadow`), so it
  never uses a user's per-user slots. Emits `[:engram, :search, :gate]` with
  `gate: :shadow`, so it never counts as live traffic.
  """
  @spec try_run((-> result)) :: result | {:error, :search_busy} when result: var
  def try_run(fun) do
    config = config()
    gate = Keyword.get(config, :gate, __MODULE__)
    status = ConcurrencyGate.try_acquire(gate, :keyword_shadow, 1)

    :telemetry.execute(@event, %{wait: 0}, %{outcome: status, gate: :shadow, upstream: :none})
    hold(status, gate, fun)
  end

  @doc """
  Admit one WHOLE search (query embed, Postgres reads, every Qdrant request)
  of `user_id`: at most `:admission_per_user` per user and `:admission_limit`
  per node in flight, waiting up to `:acquire_timeout` ms (at most
  `:admission_max_waiting_per_user` queued per user), else
  `{:error, :search_busy}` without running `fun`.

  Why: the Qdrant slot covers only Qdrant, so before this one user's 200
  parallel searches all ran their query embeds at once, drained the shared
  Finch pool and got 500s instead of busy. A separate gate process from the
  Qdrant one, so `run/2` nests inside it in the same process (the
  double-acquire raise is per gate). Released like `run/2`: on return, raise,
  exit or caller death. Same `admission_gate: pid` test seam as `gate:`.
  """
  @spec admit(term(), (-> result)) :: result | {:error, :search_busy} when result: var
  def admit(user_id, fun),
    do: through(:admission, :admission_gate, @admission, user_id, fun)

  @doc """
  Run one outbound request of a search (`upstream` names it in the log) and
  turn a Finch pool checkout timeout into `{:error, :search_busy}` with a
  warning. Every other result, raise or exit passes through untouched.
  """
  @spec pool_busy(atom(), (-> result)) :: result | {:error, :search_busy} when result: var
  def pool_busy(upstream, fun) do
    fun.()
  rescue
    e in RuntimeError ->
      if String.starts_with?(e.message, @pool_busy) do
        :telemetry.execute(@event, %{wait: 0}, %{
          outcome: :busy,
          gate: :pool,
          upstream: upstream
        })

        Logger.warning(
          "search upstream connection pool busy, refusing search_busy",
          Metadata.with_category(:warning, :search,
            upstream: upstream,
            reason_label: :pool_checkout_timeout
          )
        )

        {:error, :search_busy}
      else
        reraise e, __STACKTRACE__
      end
  end

  # Acquire on the gate named by `key` in config (a test seam) or `default`,
  # emit `@event` tagged with `kind`, then run `fun` in the slot.
  defp through(kind, key, default, user_id, fun) do
    config = config()
    gate = Keyword.get(config, key, default)
    start = System.monotonic_time()
    status = ConcurrencyGate.acquire(gate, user_id, Keyword.fetch!(config, :acquire_timeout))

    :telemetry.execute(@event, %{wait: System.monotonic_time() - start}, %{
      outcome: status,
      gate: kind,
      upstream: :none
    })

    hold(status, gate, fun)
  end

  defp config,
    do:
      Keyword.merge(
        Application.get_env(:engram, :search_gate, []),
        ServiceConfig.get(:search_gate, [])
      )

  defp hold(:ok, gate, fun) do
    fun.()
  after
    ConcurrencyGate.release(gate)
  end

  defp hold(:busy, _gate, _fun), do: {:error, :search_busy}
end
