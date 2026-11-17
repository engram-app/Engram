defmodule Engram.Search.Gate do
  @moduledoc """
  Bounds how many searches run at once on this node: at most `:per_user` per
  user and `:limit` in total (`config :engram, :search_gate`).

  Why: Qdrant runs about 4 searches at a time and queues the rest. One MCP
  client firing ~40 parallel hybrid searches a minute pushed every user's
  median search from a few ms to hundreds, and some to Qdrant's server
  timeout. This queue lives in the BEAM, is fair per user, and fails fast.

  `run/3` holds a slot of the `Engram.ConcurrencyGate` server in the CALLING
  process for the whole of `fun` (the search's Qdrant rounds, its Postgres
  reads and its query embed), released when `fun` returns, raises or exits,
  and when the caller dies (the gate monitors it). A caller that gets no
  slot within `:acquire_timeout` ms, or finds the queue full (`:max_waiting`
  in total, `:max_waiting_per_user` for its user), gets `{:error, :search_busy}`
  without running `fun`.

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
