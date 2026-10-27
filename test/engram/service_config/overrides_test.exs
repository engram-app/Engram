defmodule Engram.ServiceConfig.OverridesTest do
  # Resolution order under test: DB override, then the per-process override
  # (the test stand-in for env), then app env.
  #
  # async: true so the sandbox is NOT shared: a process outside the caller
  # chain then has no connection, which is how "the DB is down" is simulated.
  # Only this module turns the DB layer on (`:service_overrides_enabled`), so
  # the node-wide cache rows it fills are read by no other test.
  use Engram.DataCase, async: true

  import ExUnit.CaptureLog

  alias Engram.Cache
  alias Engram.ServiceConfig
  alias Engram.Vector.Qdrant

  setup do
    ServiceConfig.put_override(:service_overrides_enabled, true)
    # Env values these tests pin, so a stray app env cannot decide them.
    ServiceConfig.put_override(:tenant_idf, false)
    ServiceConfig.put_override(:index_rebuild, "off")
    :persistent_term.erase({Engram.ServiceConfig.Overrides, :ignored})
    Cache.clear_local(:service_overrides)
    Cache.clear_local(:service_overrides_last_good)
    on_exit(fn -> Cache.clear_local(:service_overrides) end)
    :ok
  end

  # A process with no `$callers` link to this test: no sandbox connection.
  defp from_unowned_process(fun) do
    parent = self()

    spawn(fn ->
      ServiceConfig.put_override(:service_overrides_enabled, true)
      ServiceConfig.put_override(:tenant_idf, false)
      send(parent, {:result, fun.()})
    end)

    assert_receive {:result, value}, 5_000
    value
  end

  describe "reads" do
    test "with no override the env value is returned unchanged" do
      assert ServiceConfig.get(:tenant_idf, :default) == false
      assert ServiceConfig.get(:index_rebuild, "off") == "off"
      assert ServiceConfig.list() == []
    end

    test "an override beats env" do
      :ok = ServiceConfig.override(:tenant_idf, true, by: "test")
      assert ServiceConfig.get(:tenant_idf, false) == true
    end

    test "clear falls back to env" do
      :ok = ServiceConfig.override(:tenant_idf, true, by: "test")
      :ok = ServiceConfig.clear(:tenant_idf, by: "test")
      assert ServiceConfig.get(:tenant_idf, false) == false
    end

    test "a key off the allowlist never reads the table" do
      Repo.query!(
        "INSERT INTO service_overrides (key, value, updated_by) VALUES ('qdrant_url', '\"http://evil\"', 't')"
      )

      ServiceConfig.put_override(:qdrant_url, "http://env")
      assert ServiceConfig.get(:qdrant_url) == "http://env"
    end

    test "the cached value holds until the TTL, then the row is re-read" do
      assert ServiceConfig.get(:tenant_idf, false) == false

      # A write that skips the eviction (raw SQL): only the TTL can surface it.
      Repo.query!(
        "INSERT INTO service_overrides (key, value, updated_by) VALUES ('tenant_idf', 'true', 't')"
      )

      assert ServiceConfig.get(:tenant_idf, false) == false
      Process.sleep(Engram.Cache.Registry.fetch!(:service_overrides).ttl + 50)
      assert ServiceConfig.get(:tenant_idf, false) == true
    end
  end

  describe "invalidation" do
    test "a write evicts locally and broadcasts the eviction to peers" do
      assert ServiceConfig.get(:tenant_idf, false) == false
      :ok = Engram.Cluster.CacheSync.subscribe()

      :ok = ServiceConfig.override(:tenant_idf, true, by: "test")

      assert_receive {:cache_sync, {:engram_cache_evict, :service_overrides, :all}}
      assert ServiceConfig.get(:tenant_idf, false) == true
    end

    test "a peer's eviction message drops this node's cached overrides" do
      assert ServiceConfig.get(:tenant_idf, false) == false
      assert {:ok, _} = Cache.get(:service_overrides, :all)

      send(Engram.Cache.Server, {:cache_sync, {:engram_cache_evict, :service_overrides, :all}})
      _ = :sys.get_state(Engram.Cache.Server)

      assert Cache.get(:service_overrides, :all) == :miss
    end
  end

  describe "DB outage" do
    test "falls back to env and does not crash" do
      log =
        capture_log(fn ->
          assert from_unowned_process(fn -> ServiceConfig.get(:tenant_idf, false) end) == false
        end)

      assert log =~ "service overrides unreadable"
    end

    test "keeps the last overrides it read rather than reverting to env" do
      :ok = ServiceConfig.override(:tenant_idf, true, by: "test")
      assert ServiceConfig.get(:tenant_idf, false) == true
      Cache.clear_local(:service_overrides)

      capture_log(fn ->
        assert from_unowned_process(fn -> ServiceConfig.get(:tenant_idf, false) end) == true
      end)
    end
  end

  describe "reads inside a transaction" do
    # The read runs on the caller's connection there. Unguarded, a failed
    # SELECT (table not migrated yet, a cancelled statement) aborts the
    # CALLER's transaction: every later statement in it fails, on every
    # write path that reads a flag.
    test "a failed read leaves the caller's transaction usable" do
      {:ok, result} =
        Repo.transaction(fn ->
          # The table is then unresolvable, as before its migration ran.
          Repo.query!("SET LOCAL search_path TO pg_catalog")

          capture_log(fn -> assert ServiceConfig.get(:tenant_idf, false) == false end)
          Repo.query!("SELECT 1").rows
        end)

      assert result == [[1]]
    end
  end

  describe "writes are validated" do
    test "an unknown key is rejected" do
      assert {:error, {:unknown_key, :qdrant_url}} =
               ServiceConfig.override(:qdrant_url, "http://x", by: "test")

      assert {:error, {:unknown_key, "nope"}} = ServiceConfig.override("nope", true, by: "test")
      assert ServiceConfig.list() == []
    end

    test "a value of the wrong type is rejected" do
      assert {:error, {:invalid_value, :tenant_idf, "yes"}} =
               ServiceConfig.override(:tenant_idf, "yes", by: "test")

      assert {:error, {:invalid_value, :index_rebuild, "maybe"}} =
               ServiceConfig.override(:index_rebuild, "maybe", by: "test")
    end

    test "a string key resolves to its allowlisted atom" do
      assert :ok = ServiceConfig.override("tenant_idf", true, by: "test")
      assert [%{key: :tenant_idf, value: true, updated_by: "test"}] = ServiceConfig.list()
    end

    test "every change is logged with operator, old and new value" do
      log =
        capture_log([level: :info], fn ->
          :ok = ServiceConfig.override(:tenant_idf, true, by: "todd")
          :ok = ServiceConfig.clear(:tenant_idf, by: "todd")
        end)

      assert log =~ "service override set"
      assert log =~ "service override cleared"
      assert log =~ "todd"
    end
  end

  describe "keys this release does not allow" do
    # The retired v5 flags and the Qdrant cluster switch left the allowlist
    # (their behaviour is the code's only one now). A row an old node writes
    # mid-rollout, or one still in the table (a later contract step deletes them), is ignored.
    # The value is a JSON literal (`~s("v2")`, `false`), as the column stores it.
    defp insert_row(key, json),
      do:
        Repo.query!(
          "INSERT INTO service_overrides (key, value, updated_by) VALUES ('#{key}', '#{json}', 't')"
        )

    test "a qdrant_active_cluster row is ignored, logged once per node" do
      insert_row("qdrant_active_cluster", ~s("v2"))
      insert_row("write_v5_layout", "false")

      log =
        capture_log([level: :warning], fn ->
          assert ServiceConfig.get(:tenant_idf, false) == false
          assert Engram.ServiceConfig.Overrides.fetch(:qdrant_active_cluster) == :error
        end)

      assert log =~ "service overrides ignored"
      assert log =~ ~s("qdrant_active_cluster")
      assert log =~ ~s("write_v5_layout")
      assert ServiceConfig.list() == []

      # The same ignored set on the next load (TTL) is not logged again.
      Cache.clear_local(:service_overrides)
      refute capture_log(fn -> ServiceConfig.get(:tenant_idf, false) end) =~ "ignored"
    end

    test "a stale v2 or old cluster row leaves Qdrant on QDRANT_URL" do
      ServiceConfig.put_override(:qdrant_url, "http://v3:6333")

      for value <- [~s("v2"), ~s("old")] do
        Repo.query!("DELETE FROM service_overrides")
        insert_row("qdrant_active_cluster", value)
        Cache.clear_local(:service_overrides)

        capture_log(fn ->
          assert ServiceConfig.get(:tenant_idf, false) == false
          assert Qdrant.base_url() == "http://v3:6333"
        end)
      end
    end

    test "the cluster switch can no longer be written" do
      assert {:error, {:unknown_key, :qdrant_active_cluster}} =
               ServiceConfig.override(:qdrant_active_cluster, "old", by: "t")
    end

    # The GO SEQUENCE invariants needed the v5 layout and the vector cache,
    # which are now always on: the rebuild switch moves on its own.
    test "index_rebuild moves to dry_run and on with nothing else set" do
      assert :ok = ServiceConfig.override(:index_rebuild, "dry_run", by: "t")
      assert :ok = ServiceConfig.override(:index_rebuild, "on", by: "t")
      assert ServiceConfig.get(:index_rebuild, "off") == "on"
    end
  end

  describe "accessors read through the override" do
    test "every overridable accessor sees a DB override" do
      :ok = ServiceConfig.override(:tenant_idf, true, by: "t")

      assert ServiceConfig.get(:tenant_idf, false) == true

      :ok = ServiceConfig.override(:index_rebuild, "dry_run", by: "t")
      assert Engram.Rebuild.mode() == :dry_run
    end
  end
end
