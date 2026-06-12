defmodule Engram.Billing.OverrideCacheTest do
  use ExUnit.Case, async: false

  alias Engram.Billing.OverrideCache

  setup do
    on_exit(fn -> OverrideCache.evict_all() end)
    :ok
  end

  test "fetch caches the function result within the TTL" do
    user_id = Ecto.UUID.generate()

    assert :miss = OverrideCache.fetch(user_id, "vaults_cap", fn -> :miss end)
    # Second fetch must NOT invoke the fun.
    assert :miss = OverrideCache.fetch(user_id, "vaults_cap", fn -> raise "should not run" end)
  end

  test "a Postgres notification for the user evicts their cached entries" do
    # The user_limit_overrides table carries an AFTER-write trigger that
    # pg_notifys the user_id — so raw-SQL writers (support runbook, e2e
    # helpers) invalidate this cache without touching the app API. This
    # pins the message handling; the trigger itself is exercised by the
    # vault-limit e2e test (lift-by-SQL then immediate retry).
    user_id = Ecto.UUID.generate()
    other_id = Ecto.UUID.generate()

    assert :miss = OverrideCache.fetch(user_id, "vaults_cap", fn -> :miss end)
    assert :miss = OverrideCache.fetch(other_id, "vaults_cap", fn -> :miss end)

    send(
      Process.whereis(OverrideCache),
      {:notification, self(), make_ref(), "user_limit_overrides_changed", user_id}
    )

    :sys.get_state(OverrideCache)

    # Evicted user re-runs the fun; unrelated user stays cached.
    assert {:hit, 42} = OverrideCache.fetch(user_id, "vaults_cap", fn -> {:hit, 42} end)
    assert :miss = OverrideCache.fetch(other_id, "vaults_cap", fn -> raise "should not run" end)
  end
end
