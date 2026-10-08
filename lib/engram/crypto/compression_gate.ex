defmodule Engram.Crypto.CompressionGate do
  @moduledoc """
  Cluster guard for envelope compression (#1872 R2). A node must not write
  format 1 while any node in the cluster cannot read it: a rolling deploy
  onto pre-R1 nodes, or a self-hoster jumping from pre-R1 straight to R2 on a
  multi-node setup. `allowed?/0` is that verdict, cached in `:persistent_term`
  so the write path (`Engram.Crypto.Envelope.mode_for/1`) pays one lookup.

  Allowed only when BOTH hold:

    * every expected member is connected: `Engram.Cluster.Readiness.rooms_reachable?/1`
      (single node with no role and no `DNS_CLUSTER_QUERY`: just this node;
      with a query, every A record but this node's own must be a connected
      peer; an empty resolution or no peers fails closed);
    * every connected peer reports `Envelope.max_read_format/0 >= 1` over
      `:erpc`. A peer without that function (pre-R1) counts as 0; an erpc
      error or timeout blocks.

  Fails closed: `false` until the first evaluation, and on any evaluation
  error. Re-evaluated on `:nodeup`/`:nodedown` and every 30 s. Each verdict
  change logs once (`:warning` when blocked, `:info` when allowed; the first
  evaluation after boot is always `:info`, a clustered boot has no peers yet)
  and emits
  `[:engram, :envelope, :compression_gate]` with `%{allowed: 0 | 1}` and
  `%{reason: atom(), node: node() | nil}`.

  The `ENVELOPE_COMPRESSION=false` kill switch is applied on top of this, in
  `Envelope.compression_on?/0`.
  """
  use GenServer

  alias Engram.Cluster.Readiness
  alias Engram.Crypto.Envelope
  alias Engram.Logger.Metadata

  require Logger

  @key {__MODULE__, :allowed}
  @refresh_ms :timer.seconds(30)
  @erpc_timeout_ms 2_000

  @type reason ::
          :cluster_reads_format_1
          | :members_missing
          | :peer_cannot_read
          | :peer_unreachable
          | :evaluation_failed
  @type verdict :: {:allowed | :blocked, reason(), node() | nil}

  @doc "The cached verdict. `false` before the first evaluation (fail closed)."
  @spec allowed?(term()) :: boolean()
  def allowed?(key \\ @key), do: :persistent_term.get(key, false)

  @doc """
  Options (tests): `:name`, `:key` (the persistent_term key), `:monitor`
  (default true, subscribe to node up/down), `:refresh_ms`, and the
  evaluation collaborators `evaluate/1` takes.
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc "Re-evaluates now and returns the cached verdict (tests, operators)."
  @spec refresh(GenServer.server()) :: boolean()
  def refresh(server \\ __MODULE__), do: GenServer.call(server, :refresh, 10_000)

  @doc """
  Computes the verdict. Collaborators injectable via `opts`: `:peers`
  (0-arity fun, default `Node.list/0`), `:multicall` (fun of the peer list
  returning `:erpc.multicall/5`-shaped results), and the
  `Readiness.rooms_reachable?/1` options (`:role`, `:query`, `:resolver`,
  `:self_ip`).
  """
  @spec evaluate(keyword()) :: verdict()
  def evaluate(opts \\ []) do
    peers = Keyword.get(opts, :peers, &Node.list/0).()

    readiness =
      opts
      |> Keyword.take([:role, :query, :resolver, :self_ip])
      |> Keyword.merge(peers: fn -> peers end, sync: fn -> :ok end)

    if Readiness.rooms_reachable?(readiness),
      do: peers_verdict(peers, Keyword.get(opts, :multicall, &multicall/1)),
      else: {:blocked, :members_missing, nil}
  end

  defp multicall(peers),
    do: :erpc.multicall(peers, Envelope, :max_read_format, [], @erpc_timeout_ms)

  defp peers_verdict(peers, multicall) do
    peers
    |> Enum.zip(multicall.(peers))
    |> Enum.find_value({:allowed, :cluster_reads_format_1, nil}, fn
      {_node, {:ok, format}} when is_integer(format) and format >= 1 -> nil
      {node, {:ok, _}} -> {:blocked, :peer_cannot_read, node}
      {node, {:error, {:exception, :undef, _}}} -> {:blocked, :peer_cannot_read, node}
      {node, _} -> {:blocked, :peer_unreachable, node}
    end)
  end

  @impl true
  def init(opts) do
    if Keyword.get(opts, :monitor, true), do: :ok = :net_kernel.monitor_nodes(true)

    state = %{
      opts: opts,
      key: Keyword.get(opts, :key, @key),
      refresh_ms: Keyword.get(opts, :refresh_ms, @refresh_ms),
      allowed: nil
    }

    # Synchronous first evaluation: a single node knows its answer before
    # anything can encrypt. Bounded by the resolver (1.5 s) on a cluster.
    state = evaluate_and_store(state)
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:refresh, _from, state) do
    state = evaluate_and_store(state)
    {:reply, state.allowed, state}
  end

  @impl true
  def handle_info(:tick, state) do
    schedule(state)
    {:noreply, evaluate_and_store(state)}
  end

  def handle_info({event, _node}, state) when event in [:nodeup, :nodedown],
    do: {:noreply, evaluate_and_store(state)}

  defp schedule(%{refresh_ms: ms}), do: Process.send_after(self(), :tick, ms)

  defp evaluate_and_store(state) do
    {verdict, reason, node} = safe_evaluate(state.opts)
    allowed = verdict == :allowed

    if allowed != :persistent_term.get(state.key, false),
      do: :persistent_term.put(state.key, allowed)

    if allowed != state.allowed, do: report(allowed, reason, node, is_nil(state.allowed))
    %{state | allowed: allowed}
  end

  defp safe_evaluate(opts) do
    evaluate(opts)
  rescue
    _ -> {:blocked, :evaluation_failed, nil}
  catch
    _kind, _reason -> {:blocked, :evaluation_failed, nil}
  end

  defp report(allowed, reason, node, first?) do
    :telemetry.execute(
      [:engram, :envelope, :compression_gate],
      %{allowed: if(allowed, do: 1, else: 0)},
      %{reason: reason, node: node}
    )

    cond do
      allowed ->
        Logger.info(
          "envelope compression allowed: every cluster node reads format 1",
          Metadata.with_category(:info, :crypto, reason: reason)
        )

      first? ->
        # Clustered boot: no peers yet, expected. A block after the gate
        # was once allowed is the anomaly worth :warning.
        Logger.info(
          "envelope compression blocked at boot: writing format 0 until every cluster node reads format 1",
          Metadata.with_category(:info, :crypto, reason: reason, peer: inspect(node))
        )

      true ->
        Logger.warning(
          "envelope compression blocked: writing format 0 until every cluster node reads format 1",
          Metadata.with_category(:warning, :crypto, reason: reason, peer: inspect(node))
        )
    end
  end
end
