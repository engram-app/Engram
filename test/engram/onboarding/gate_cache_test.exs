defmodule Engram.Onboarding.GateCacheTest do
  use Engram.DataCase, async: false

  alias Engram.Cluster.CacheSync
  alias Engram.Onboarding.GateCache

  setup do
    on_exit(fn -> GateCache.evict_all() end)
    :ok
  end

  # Processing of PubSub messages is async; a synchronous call to the cache
  # GenServer flushes everything ahead of it in the mailbox.
  defp sync, do: :sys.get_state(GateCache)

  describe "core verdict cache" do
    test "passed?/1 is false for an unknown user" do
      refute GateCache.passed?(Ecto.UUID.generate())
    end

    test "mark_passed/1 then passed?/1 is true" do
      id = Ecto.UUID.generate()
      :ok = GateCache.mark_passed(id)
      assert GateCache.passed?(id)
    end

    test "evict/1 removes the verdict" do
      id = Ecto.UUID.generate()
      :ok = GateCache.mark_passed(id)
      :ok = GateCache.evict(id)
      refute GateCache.passed?(id)
    end

    test "entries expire after their ttl" do
      id = Ecto.UUID.generate()
      :ok = GateCache.mark_passed(id, 0)
      refute GateCache.passed?(id)
    end
  end

  describe "cluster invalidation" do
    test "evict on one node clears peers via cache_sync broadcast" do
      id = Ecto.UUID.generate()
      :ok = GateCache.mark_passed(id)

      # Simulate the message arriving from a peer node.
      CacheSync.broadcast({:onboarding_gate_evict, id})
      sync()

      refute GateCache.passed?(id)
    end

    test "terms version invalidation clears ALL verdicts" do
      # A new required terms floor can flip every passed user back to
      # failing — the gate must re-derive for everyone.
      id = Ecto.UUID.generate()
      :ok = GateCache.mark_passed(id)

      CacheSync.broadcast(:version_evict_all)
      sync()

      refute GateCache.passed?(id)
    end
  end

  describe "eviction write-sites" do
    test "set_profile evicts the user's verdict" do
      user = insert(:user, onboarding_profile: %{})
      :ok = GateCache.mark_passed(user.id)

      {:ok, _} = Engram.Onboarding.set_profile(user, %{uses_obsidian: true, tools: ["claude"]})

      refute GateCache.passed?(user.id)
    end

    test "delete_vault evicts the user's verdict" do
      user = insert(:user)
      {:ok, vault} = Engram.Vaults.create_vault(user, %{name: "V"})
      :ok = GateCache.mark_passed(user.id)

      {:ok, _} = Engram.Vaults.delete_vault(user, vault.id)

      refute GateCache.passed?(user.id)
    end

    test "paddle subscription upsert evicts the user's verdict" do
      user = insert(:user)
      :ok = GateCache.mark_passed(user.id)

      {:ok, _} =
        Engram.Billing.upsert_from_paddle_event(%{
          "event_type" => "subscription.created",
          "data" => %{
            "id" => "sub_gatecache_test",
            "customer_id" => "ctm_gatecache_test",
            "status" => "active",
            "custom_data" => %{"user_id" => user.id},
            "items" => [%{"price" => %{"id" => "pri_starter_monthly_test"}}],
            "current_billing_period" => %{"ends_at" => "2026-07-01T00:00:00Z"}
          }
        })

      refute GateCache.passed?(user.id)
    end
  end
end
