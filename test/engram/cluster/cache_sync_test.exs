defmodule Engram.Cluster.CacheSyncTest do
  use ExUnit.Case, async: false
  alias Engram.Cluster.CacheSync

  test "broadcast reaches a subscriber on the documented topic with the documented shape" do
    :ok = CacheSync.subscribe()
    :ok = CacheSync.broadcast({:dek_evict, 42})
    assert_receive {:cache_sync, {:dek_evict, 42}}
  end

  test "topic/0 is stable" do
    assert is_binary(CacheSync.topic())
  end
end
