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
  refusal in a later request comes after its embed and budget token were
  spent. Accepted: bounded, and it surfaces as an error, never a partial page.

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

  Each run emits `[:engram, :search, :gate]` with `%{wait: native}` (time to
  a slot or to the refusal) and `%{outcome: :ok | :busy}`. No user id.

  Test seam: `ServiceConfig.put_override(:search_gate, gate: pid, ...)` points
  a test's searches at its own unregistered gate.
  """

  alias Engram.ConcurrencyGate
  alias Engram.ServiceConfig

  @event [:engram, :search, :gate]

  def child_spec(opts), do: %{id: __MODULE__, start: {__MODULE__, :start_link, [opts]}}

  @doc "Start the gate from `config :engram, :search_gate`; `opts` win."
  def start_link(opts \\ []) do
    config = Keyword.merge(Application.get_env(:engram, :search_gate, []), opts)

    ConcurrencyGate.start_link(
      limit: Keyword.fetch!(config, :limit),
      per_key: Keyword.fetch!(config, :per_user),
      max_waiting: Keyword.fetch!(config, :max_waiting),
      max_waiting_per_key: Keyword.fetch!(config, :max_waiting_per_user),
      name: Keyword.get(config, :name, __MODULE__)
    )
  end

  @spec run(term(), (-> result)) :: result | {:error, :search_busy} when result: var
  def run(user_id, fun) do
    config =
      Keyword.merge(
        Application.get_env(:engram, :search_gate, []),
        ServiceConfig.get(:search_gate, [])
      )

    gate = Keyword.get(config, :gate, __MODULE__)
    start = System.monotonic_time()
    status = ConcurrencyGate.acquire(gate, user_id, Keyword.fetch!(config, :acquire_timeout))
    :telemetry.execute(@event, %{wait: System.monotonic_time() - start}, %{outcome: status})

    case status do
      :ok ->
        try do
          fun.()
        after
          ConcurrencyGate.release(gate)
        end

      :busy ->
        {:error, :search_busy}
    end
  end
end
