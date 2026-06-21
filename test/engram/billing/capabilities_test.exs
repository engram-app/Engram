defmodule Engram.Billing.CapabilitiesTest do
  # async: false — Billing.capabilities/1 reads through the process-global
  # EntitlementCache (named ETS, not sandboxed), so concurrent users of the
  # same cache could observe each other's entries. evict_all between tests
  # keeps them isolated.
  use Engram.DataCase, async: false

  alias Engram.Billing
  alias Engram.Billing.EntitlementCache

  setup do
    on_exit(fn -> EntitlementCache.evict_all() end)
    :ok
  end

  test "resolves the free-tier matrix for a user with no subscription" do
    user = insert(:user)
    caps = Billing.capabilities(user)

    assert caps.tier == "free"
    assert caps.limits["notes_cap"] == 10_000
    assert caps.limits["vaults_cap"] == 1
    # Boolean feature stays a boolean; integer "unlimited" caps serialize to nil.
    assert caps.limits["api_write_enabled"] == false
    assert caps.limits["ai_queries_per_day"] == nil
  end

  test "resolves paid-tier limits when the user has an entitling subscription" do
    user = insert(:user)
    insert(:subscription, user: user, tier: "starter", status: "active")

    caps = Billing.capabilities(user)

    assert caps.tier == "starter"
    assert caps.limits["notes_cap"] == 50_000
    assert caps.limits["vaults_cap"] == 5
    assert caps.limits["api_write_enabled"] == true
  end

  test "exposes every defined limit key as a JSON-safe value" do
    user = insert(:user)
    caps = Billing.capabilities(user)

    expected_keys = Enum.map(Engram.Billing.LimitKeys.all(), &Atom.to_string/1)
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
    assert %{tier: "free"} = Billing.capabilities(user)

    # Explicit eviction (what the chokepoint and override sweep call) forces a
    # re-derivation that now sees the paid tier.
    :ok = EntitlementCache.evict(user.id)
    caps = Billing.capabilities(user)
    assert caps.tier == "pro"
    assert caps.limits["notes_cap"] == nil
  end
end
