defmodule Engram.Billing.CapabilitiesTest do
  # async: false — Billing.capabilities/1 reads through the process-global
  # EntitlementCache (named ETS, not sandboxed), so concurrent users of the
  # same cache could observe each other's entries. evict_all between tests
  # keeps them isolated.
  use Engram.DataCase, async: false

  alias Engram.Billing
  alias Engram.Billing.EntitlementCache
  alias Engram.Billing.LimitKeys
  alias Engram.IndexBudgetHelpers

  setup do
    on_exit(fn -> EntitlementCache.evict_all() end)
    :ok
  end

  test "resolves the free-tier matrix for a user with no subscription" do
    user = insert(:user)
    caps = Billing.capabilities(user)

    assert caps.tier == "free"
    assert caps.limits["notes_cap"] == 3_000
    assert caps.limits["vaults_cap"] == 1
    # #1974: API access is every tier's; there is no write flag any more.
    assert caps.limits["api_rps_cap"] == 30
    refute Map.has_key?(caps.limits, "api_write_enabled")
    assert caps.limits["ai_searches_per_day"] == 20
  end

  test "resolves paid-tier limits when the user has an entitling subscription" do
    user = insert(:user)
    insert(:subscription, user: user, tier: "starter", status: "active")

    caps = Billing.capabilities(user)

    assert caps.tier == "starter"
    assert caps.limits["notes_cap"] == 50_000
    assert caps.limits["vaults_cap"] == 10
    assert caps.limits["api_rps_cap"] == 30
  end

  # Removing a limit key needs no migration: lookups are keyed by the
  # requested key, so a leftover override row is never read.
  test "a leftover override row for a removed key is inert" do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "api_write_enabled", value: %{"v" => false})
    insert(:user_limit_override, user: user, key: "mcp_connections_cap", value: %{"v" => 1})

    caps = Billing.capabilities(user)
    refute Map.has_key?(caps.limits, "api_write_enabled")
    refute Map.has_key?(caps.limits, "mcp_connections_cap")
  end

  test "exposes every defined limit key as a JSON-safe value" do
    user = insert(:user)
    caps = Billing.capabilities(user)

    expected_keys = Enum.map(LimitKeys.all(), &Atom.to_string/1)
    assert Enum.sort(Map.keys(caps.limits)) == Enum.sort(expected_keys)

    Enum.each(caps.limits, fn {_key, v} ->
      assert is_integer(v) or is_boolean(v) or is_nil(v)
    end)
  end

  test "serves a cached snapshot until the entitlement cache is evicted" do
    user = insert(:user)

    # Warm the cache while the user is on Free.
    assert %{tier: "free"} = Billing.capabilities(user)

    # A raw subscription insert does NOT route through the eviction chokepoint
    # (broadcast_subscription_activated/2), so the cached Free snapshot stands.
    insert(:subscription, user: user, tier: "pro", status: "active")
    # The row-level :subscription cache IS evicted by the subscriptions_changed
    # trigger on commit (the sandbox never commits, so mirror it here); the
    # entitlement snapshot is what this test pins.
    Engram.Cache.evict(:subscription, user.id)
    assert %{tier: "free"} = Billing.capabilities(user)

    # Explicit eviction (what the chokepoint and override sweep call) forces a
    # re-derivation that now sees the paid tier.
    :ok = EntitlementCache.evict(user.id)
    caps = Billing.capabilities(user)
    assert caps.tier == "pro"
    assert caps.limits["notes_cap"] == nil
  end

  # The v5 go flag (INDEX_BUDGET_ENABLED) switches the note caps for every
  # reader at once; at its default they are main's.
  describe "v5 plan limits" do
    test "default: main's note caps" do
      assert Billing.capabilities(insert(:user)).limits["notes_cap"] == 3_000
      assert LimitKeys.plan_limits() == :legacy
    end

    test "flag on: the 2026-10-19 note caps", _ctx do
      IndexBudgetHelpers.enable_index_budget()
      assert LimitKeys.plan_limits() == :v5

      free = insert(:user)
      starter = insert(:user)
      insert(:subscription, user: starter, tier: "starter", status: "active")
      pro = insert(:user)
      insert(:subscription, user: pro, tier: "pro", status: "active")

      assert Billing.capabilities(free).limits["notes_cap"] == 2_000
      assert Billing.capabilities(starter).limits["notes_cap"] == 20_000
      assert Billing.capabilities(pro).limits["notes_cap"] == 40_000
      assert Billing.tier_cap(:pro, :notes_cap) == 40_000
    end
  end
end
