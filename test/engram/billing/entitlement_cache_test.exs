defmodule Engram.Billing.EntitlementCacheTest do
  use ExUnit.Case, async: false

  alias Engram.Billing.EntitlementCache

  setup do
    on_exit(fn -> EntitlementCache.evict_all() end)
    :ok
  end

  test "fetch caches the function result and serves it without re-running fun" do
    user_id = Ecto.UUID.generate()
    value = %{tier: "free", limits: %{"notes_cap" => 10_000}}

    assert ^value = EntitlementCache.fetch(user_id, fn -> value end)
    # Second fetch must NOT invoke the fun.
    assert ^value = EntitlementCache.fetch(user_id, fn -> raise "should not run" end)
  end

  test "evict drops one user, leaving others cached" do
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    assert :a = EntitlementCache.fetch(user_id, fn -> :a end)
    assert :b = EntitlementCache.fetch(other_id, fn -> :b end)

    :ok = EntitlementCache.evict(user_id)

    # Evicted user re-runs the fun; unrelated user stays cached.
    assert :a2 = EntitlementCache.fetch(user_id, fn -> :a2 end)
    assert :b = EntitlementCache.fetch(other_id, fn -> raise "should not run" end)
  end

  test "evict_all flushes every entry" do
    a = Ecto.UUID.generate()
    b = Ecto.UUID.generate()

    assert :a = EntitlementCache.fetch(a, fn -> :a end)
    assert :b = EntitlementCache.fetch(b, fn -> :b end)

    :ok = EntitlementCache.evict_all()

    assert :a2 = EntitlementCache.fetch(a, fn -> :a2 end)
    assert :b2 = EntitlementCache.fetch(b, fn -> :b2 end)
  end

  test "a Postgres notification for the user evicts their cached entry" do
    # Shared with OverrideCache: the user_limit_overrides AFTER-write trigger
    # pg_notifys the user_id, so raw-SQL override writes (support runbook,
    # e2e helpers) invalidate the resolved-entitlement cache too. This pins
    # the message handling.
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    assert :cached = EntitlementCache.fetch(user_id, fn -> :cached end)
    assert :other = EntitlementCache.fetch(other_id, fn -> :other end)

    send(
      Process.whereis(EntitlementCache),
      {:notification, self(), make_ref(), "user_limit_overrides_changed", user_id}
    )

    # Force the GenServer to process the message before asserting.
    :sys.get_state(EntitlementCache)

    assert :rederived = EntitlementCache.fetch(user_id, fn -> :rederived end)
    assert :other = EntitlementCache.fetch(other_id, fn -> raise "should not run" end)
  end
end
