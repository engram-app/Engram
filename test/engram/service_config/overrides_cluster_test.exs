defmodule Engram.ServiceConfig.OverridesClusterTest do
  # The v2 flip against a REAL second node. The rpc runs on one node and its
  # own env says QDRANT_URL_V2 is set; a peer whose task def lacks it would
  # silently keep writing the old cluster (Qdrant.endpoint/0 falls back).
  use Engram.DataCase, async: false

  alias Engram.ServiceConfig

  @moduletag :cluster

  setup do
    ServiceConfig.put_override(:service_overrides_enabled, true)
    ServiceConfig.put_override(:qdrant_url_v2, "http://v2:6333")
    ServiceConfig.put_override(:qdrant_api_key_v2, "v2-key")
    Engram.Cache.clear_local(:service_overrides)
    on_exit(fn -> Engram.Cache.clear_local(:service_overrides) end)

    {peer_pid, peer_node} = Engram.ClusterCase.start_peer!([], &on_exit/1)
    %{peer_pid: peer_pid, peer_node: peer_node}
  end

  test "the flip to v2 is refused while a connected node lacks QDRANT_URL_V2 or its key", ctx do
    assert {:error, {:invariant, message}} =
             ServiceConfig.override(:qdrant_active_cluster, "v2", by: "t")

    assert message =~ to_string(ctx.peer_node)

    :ok = :peer.call(ctx.peer_pid, Application, :put_env, [:engram, :qdrant_url_v2, "http://v2"])

    assert {:error, {:invariant, _}} =
             ServiceConfig.override(:qdrant_active_cluster, "v2", by: "t")

    :ok = :peer.call(ctx.peer_pid, Application, :put_env, [:engram, :qdrant_api_key_v2, "k"])
    assert :ok = ServiceConfig.override(:qdrant_active_cluster, "v2", by: "t")
  end
end
