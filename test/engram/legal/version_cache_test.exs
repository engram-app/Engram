defmodule Engram.Legal.VersionCacheTest do
  use Engram.DataCase, async: false
  import Engram.LegalFixtures
  alias Engram.Legal.VersionCache

  setup do
    on_exit(&reset_version_cache/0)
    reset_version_cache()
    :ok
  end

  test "memoizes required_floor and reflects invalidation" do
    insert_version(version: "2026-05-19", material: true, effective_date: nil)
    assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

    insert_version(version: "2026-06-01", material: true, effective_date: ~D[2000-01-01])
    # still cached at the old value until invalidated
    assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

    reset_version_cache()
    assert VersionCache.required_floor("terms_of_service") == "2026-06-01"
  end

  test "caches current_version and hash_for" do
    insert_version(version: "2026-05-19", content_hash: "h")
    assert VersionCache.current_version("terms_of_service") == "2026-05-19"
    assert VersionCache.hash_for("terms_of_service", "2026-05-19") == "h"
  end

  describe "cross-node invalidation (PubSub round-trip)" do
    alias Engram.Cluster.CacheSync
    alias Engram.Legal.VersionCache.Invalidator

    test "invalidate_all/0 broadcasts the documented evict-all message" do
      CacheSync.subscribe()
      VersionCache.invalidate_all()
      assert_receive {:cache_sync, :version_evict_all}
    end

    test "a peer evict message clears the local cache (next read reloads)" do
      insert_version(version: "2026-05-19", material: true, effective_date: nil)
      assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

      insert_version(version: "2026-06-01", material: true, effective_date: ~D[2000-01-01])
      # Still memoized at the old floor until an eviction lands.
      assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

      CacheSync.broadcast(:version_evict_all)
      # Barrier: sync the Invalidator so its handle_info has run.
      _ = :sys.get_state(Invalidator)

      assert VersionCache.required_floor("terms_of_service") == "2026-06-01"
    end

    test "Invalidator ignores a foreign cache_sync message (DekCache's) without crashing" do
      pid = Process.whereis(Invalidator)
      insert_version(version: "2026-05-19", material: true, effective_date: nil)
      assert VersionCache.required_floor("terms_of_service") == "2026-05-19"

      CacheSync.broadcast({:dek_evict, 1})
      _ = :sys.get_state(Invalidator)

      assert Process.alive?(pid)
      # foreign message must NOT have erased the cache
      assert VersionCache.required_floor("terms_of_service") == "2026-05-19"
    end
  end
end
