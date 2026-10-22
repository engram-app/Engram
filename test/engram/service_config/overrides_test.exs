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
    ServiceConfig.put_override(:write_v5_layout, false)
    ServiceConfig.put_override(:vector_cache_enabled, false)
    ServiceConfig.put_override(:index_rebuild, "off")
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

    test "the GO SEQUENCE invariants hold across override and env" do
      assert {:error, {:invariant, _}} = ServiceConfig.override(:index_rebuild, "on", by: "t")

      assert {:error, {:invariant, _}} =
               ServiceConfig.override(:index_rebuild, "dry_run", by: "t")

      :ok = ServiceConfig.override(:write_v5_layout, true, by: "t")
      :ok = ServiceConfig.override(:index_rebuild, "dry_run", by: "t")
      # `on` also needs the vector cache.
      assert {:error, {:invariant, _}} = ServiceConfig.override(:index_rebuild, "on", by: "t")
      :ok = ServiceConfig.override(:vector_cache_enabled, true, by: "t")
      :ok = ServiceConfig.override(:index_rebuild, "on", by: "t")

      # Turning the layout off under a running rebuild is refused too.
      assert {:error, {:invariant, _}} = ServiceConfig.override(:write_v5_layout, false, by: "t")
      assert {:error, {:invariant, _}} = ServiceConfig.clear(:write_v5_layout, by: "t")
    end

    test "the v2 cluster is refused while its URL is not configured" do
      ServiceConfig.put_override(:qdrant_url_v2, nil)

      assert {:error, {:invariant, _}} =
               ServiceConfig.override(:qdrant_active_cluster, "v2", by: "t")

      ServiceConfig.put_override(:qdrant_url_v2, "http://v2")
      ServiceConfig.put_override(:qdrant_api_key_v2, "v2-key")
      assert :ok = ServiceConfig.override(:qdrant_active_cluster, "v2", by: "t")
    end

    # An env change under a live override can leave the effective config
    # violating an invariant. That must not refuse every later write: a kill
    # switch (INDEX_REBUILD=off) is exactly the write an incident needs.
    test "a violation the write did not introduce does not block it" do
      ServiceConfig.put_override(:legacy_filter_fields, false)
      :ok = ServiceConfig.override(:qdrant_tenant_graph, true, by: "t")
      ServiceConfig.put_override(:legacy_filter_fields, true)

      assert :ok = ServiceConfig.override(:index_rebuild, "off", by: "t")
      assert :ok = ServiceConfig.override(:tenant_idf, true, by: "t")
      # A write that would ADD a violation is still refused.
      assert {:error, {:invariant, _}} = ServiceConfig.override(:index_rebuild, "on", by: "t")
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

  describe "the v2 flip checks every connected node" do
    # The peer list and the multicall are injected (as CompressionGate's are),
    # so CI proves the refusal without a second BEAM node.
    setup do
      ServiceConfig.put_override(:qdrant_url_v2, "http://v2")
      ServiceConfig.put_override(:qdrant_api_key_v2, "v2-key")
      :ok
    end

    defp flip(answer) do
      ServiceConfig.override(:qdrant_active_cluster, "v2",
        by: "t",
        peers: fn -> [:"peer@10.0.0.2"] end,
        multicall: fn [:"peer@10.0.0.2"] -> [answer] end
      )
    end

    test "a node missing the URL or key is refused, by name" do
      assert {:error, {:invariant, message}} = flip({:ok, false})
      assert message =~ "peer@10.0.0.2 (missing)"
    end

    test "a node that does not answer is refused" do
      assert {:error, {:invariant, message}} = flip({:error, {:erpc, :noconnection}})
      assert message =~ "peer@10.0.0.2 (unreachable)"
    end

    test "a node on an older release (no v2_configured?/0) is refused" do
      assert {:error, {:invariant, message}} = flip({:error, {:exception, :undef, []}})
      assert message =~ "peer@10.0.0.2 (old_release)"
    end

    test "a multicall that answers for fewer nodes than asked fails closed" do
      assert {:error, {:invariant, message}} =
               ServiceConfig.override(:qdrant_active_cluster, "v2",
                 by: "t",
                 peers: fn -> [:"a@10.0.0.2", :"b@10.0.0.3"] end,
                 multicall: fn _ -> [{:ok, true}] end
               )

      assert message =~ "b@10.0.0.3 (unreachable)"
    end

    test "every node configured: the flip goes through" do
      assert :ok = flip({:ok, true})
    end

    test "this node needs QDRANT_API_KEY_V2 as well as the URL" do
      ServiceConfig.put_override(:qdrant_api_key_v2, nil)
      assert {:error, {:invariant, message}} = flip({:ok, true})
      assert message =~ "(missing)"
    end
  end

  describe "override vs the env pin" do
    # The override wins whenever the table is readable; a node booted with the
    # DB unreachable runs on env, so a mismatch is a latent split brain. It is
    # read every 15s TTL, so the log fires once per distinct pair (a warning:
    # an error is a Sentry event each time) and the gauge carries the state.
    setup do
      :persistent_term.erase({Engram.ServiceConfig.Overrides, :env_mismatch})
      ServiceConfig.put_override(:qdrant_url_v2, "http://v2")
      ServiceConfig.put_override(:qdrant_api_key_v2, "v2-key")
      ref = make_ref()
      test = self()

      :telemetry.attach(
        "mismatch-#{inspect(ref)}",
        [:engram, :qdrant, :active_cluster],
        fn _event, measurements, _meta, _ -> send(test, {ref, measurements}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach("mismatch-#{inspect(ref)}") end)
      %{ref: ref}
    end

    defp reload do
      Cache.clear_local(:service_overrides)
      capture_log(fn -> ServiceConfig.get(:qdrant_active_cluster, "old") end)
    end

    test "logs one warning per distinct override/env pair, and again on a change", ctx do
      ServiceConfig.put_override(:qdrant_active_cluster, "v2")
      :ok = ServiceConfig.override(:qdrant_active_cluster, "old", by: "t")

      first =
        capture_log([level: :warning], fn ->
          assert ServiceConfig.get(:qdrant_active_cluster, "old") == "old"
        end)

      assert first =~ "disagrees with env"
      assert first =~ "[warning]"
      assert_receive {_, %{mismatch: 1}}
      refute reload() =~ "disagrees with env"
      assert_receive {r, %{mismatch: 1}} when r == ctx.ref

      # Same override, env re-pinned the same way: still the same pair.
      ServiceConfig.put_override(:qdrant_active_cluster, "old")
      refute reload() =~ "disagrees with env"
      assert_receive {_, %{mismatch: 0}}

      ServiceConfig.put_override(:qdrant_active_cluster, "v2")
      assert reload() =~ "disagrees with env"
    end

    test "no env pin, or a matching one: gauge 0, no log", ctx do
      :ok = ServiceConfig.override(:qdrant_active_cluster, "old", by: "t")
      refute reload() =~ "disagrees"
      assert_receive {r, %{mismatch: 0}} when r == ctx.ref
    end
  end

  describe "accessors read through the override" do
    test "every v5 flag accessor sees a DB override" do
      ServiceConfig.put_override(:embed_models_per_plan, false)
      ServiceConfig.put_override(:index_budget_enabled, false)
      ServiceConfig.put_override(:chunk_text_write, false)
      ServiceConfig.put_override(:chunk_text_read, false)
      ServiceConfig.put_override(:v5_payload_format, false)
      ServiceConfig.put_override(:qdrant_tenant_graph, false)

      refute Engram.Indexing.VectorCache.enabled?()
      refute Engram.Indexing.budget_enabled?()
      refute Qdrant.write_v5_layout?()
      refute Qdrant.chunk_text_read?()

      for key <- [
            :vector_cache_enabled,
            :index_budget_enabled,
            :embed_models_per_plan,
            :tenant_idf
          ],
          do: :ok = ServiceConfig.override(key, true, by: "t")

      assert Engram.Indexing.VectorCache.enabled?()
      assert Engram.Indexing.budget_enabled?()
      assert ServiceConfig.get(:embed_models_per_plan, false) == true

      # write_v5_layout still implies the payload format and chunk text reads.
      :ok = ServiceConfig.override(:write_v5_layout, true, by: "t")
      assert Qdrant.write_v5_layout?()
      assert Qdrant.v5_payload_format?()
      assert Qdrant.chunk_text_read?()

      :ok = ServiceConfig.override(:index_rebuild, "dry_run", by: "t")
      assert Engram.Rebuild.mode() == :dry_run
    end

    test "the active cluster override routes the Qdrant client" do
      ServiceConfig.put_override(:qdrant_url, "http://old:6333")
      ServiceConfig.put_override(:qdrant_url_v2, "http://v2:6333")
      ServiceConfig.put_override(:qdrant_api_key_v2, "v2-key")
      assert Qdrant.base_url() == "http://old:6333"

      :ok = ServiceConfig.override(:qdrant_active_cluster, "v2", by: "t")
      assert Qdrant.base_url() == "http://v2:6333"

      :ok = ServiceConfig.override(:qdrant_active_cluster, "old", by: "t")
      assert Qdrant.base_url() == "http://old:6333"
    end
  end
end
