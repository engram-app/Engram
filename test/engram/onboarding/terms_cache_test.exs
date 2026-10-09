defmodule Engram.Onboarding.TermsCacheTest do
  use Engram.DataCase, async: false

  alias Engram.Cache
  alias Engram.Cluster.CacheSync
  alias Engram.Onboarding

  test "miss until put, scoped per {user, document}" do
    assert Cache.get(:terms, {7, "terms_of_service"}) == :miss
    Cache.put(:terms, {7, "terms_of_service"}, "2026-05-19")
    assert Cache.get(:terms, {7, "terms_of_service"}) == {:ok, "2026-05-19"}
    assert Cache.get(:terms, {7, "privacy_policy"}) == :miss
  end

  test "has a TTL backstop" do
    assert %{ttl: ttl} = Enum.find(Engram.Cache.Registry.caches(), &(&1.name == :terms))
    assert is_integer(ttl)
  end

  # Another node may hold the old version; accepting must evict it there too.
  test "accepting both documents evicts them cluster-wide" do
    user = insert(:user)
    :ok = CacheSync.subscribe()
    Cache.put(:terms, {user.id, "terms_of_service"}, "2020-01-01")
    Cache.put(:terms, {user.id, "privacy_policy"}, "2020-01-01")

    {:ok, _} = Onboarding.accept_terms(user, "2026-06-01", "h1", "2026-06-01", "h2", %{})

    for doc <- ["terms_of_service", "privacy_policy"] do
      assert_receive {:cache_sync, {:engram_cache_evict, :terms, {_, ^doc}}}
      refute Cache.get(:terms, {user.id, doc}) == {:ok, "2020-01-01"}
    end
  end

  test "accepting the ToS alone evicts it cluster-wide" do
    user = insert(:user)
    :ok = CacheSync.subscribe()
    Cache.put(:terms, {user.id, "terms_of_service"}, "2020-01-01")

    {:ok, _} = Onboarding.accept_terms(user, "2026-06-01", %{})

    assert_receive {:cache_sync, {:engram_cache_evict, :terms, {_, "terms_of_service"}}}
    refute Cache.get(:terms, {user.id, "terms_of_service"}) == {:ok, "2020-01-01"}
  end

  # The read goes through Cache.fetch, so an eviction during it wins.
  test "the gate reads the accepted version through the cache" do
    prev = Application.get_env(:engram, :billing_enabled)
    Application.put_env(:engram, :billing_enabled, true)
    on_exit(fn -> Application.put_env(:engram, :billing_enabled, prev) end)
    user = insert(:user)
    {:ok, _} = Onboarding.accept_terms(user, "2026-06-01", %{})
    Cache.evict_local(:terms, {user.id, "terms_of_service"})
    _ = Onboarding.status(user)
    assert Cache.get(:terms, {user.id, "terms_of_service"}) == {:ok, "2026-06-01"}
  end
end
