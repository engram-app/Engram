defmodule Engram.Cluster.Capability do
  @moduledoc """
  "Does every node of the cluster run a release that can do X?" The one
  verdict a rolling-deploy guard needs (`Engram.Crypto.CompressionGate`,
  `Engram.Workers.ReconcileNotePayloads.cluster_writes_n?/1`).

  Allowed only when BOTH hold:

    * every expected member is connected: `Engram.Cluster.Readiness.rooms_reachable?/1`.
      A single node with no role and no `DNS_CLUSTER_QUERY` is just this node;
      with a query, every A record but this node's own must be a connected
      peer, so a just-booted node not yet joined to the old ones fails closed,
      and an empty resolution fails closed;
    * every connected peer answers `mod.fun()` over `:erpc` (2 s) with a value
      `ok?` accepts. A peer without the function (a previous release, `:undef`)
      lacks it; an erpc error or timeout counts as unreachable.

  This node is never asked: it runs the caller's code.

  Collaborators injectable via `opts` (tests): `:peers` (0-arity, default
  `Node.list/0`), `:multicall` (fun of the peer list returning
  `:erpc.multicall/5`-shaped results), and the `Readiness.rooms_reachable?/1`
  options (`:role`, `:query`, `:resolver`, `:self_ip`).
  """

  alias Engram.Cluster.Readiness

  @erpc_timeout_ms 2_000

  @type verdict ::
          :allowed
          | {:blocked, :members_missing | :peer_lacks | :peer_unreachable, node() | nil}

  @spec evaluate(module(), atom(), (term() -> boolean()), keyword()) :: verdict()
  def evaluate(mod, fun, ok?, opts \\ []) do
    peers = Keyword.get(opts, :peers, &Node.list/0).()

    readiness =
      opts
      |> Keyword.take([:role, :query, :resolver, :self_ip])
      |> Keyword.merge(peers: fn -> peers end, sync: fn -> :ok end)

    if Readiness.rooms_reachable?(readiness) do
      multicall =
        Keyword.get(opts, :multicall, &:erpc.multicall(&1, mod, fun, [], @erpc_timeout_ms))

      peers
      |> Enum.zip(multicall.(peers))
      |> Enum.find_value(:allowed, fn
        {node, {:ok, value}} -> if ok?.(value), do: nil, else: {:blocked, :peer_lacks, node}
        {node, {:error, {:exception, :undef, _}}} -> {:blocked, :peer_lacks, node}
        {node, _} -> {:blocked, :peer_unreachable, node}
      end)
    else
      {:blocked, :members_missing, nil}
    end
  end
end
