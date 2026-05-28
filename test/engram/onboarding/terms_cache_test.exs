defmodule Engram.Onboarding.TermsCacheTest do
  use ExUnit.Case, async: false
  alias Engram.Onboarding.TermsCache

  setup do
    on_exit(fn -> Application.delete_env(:engram, Engram.Cache) end)
    :ok
  end

  describe ":ets backend (default)" do
    test "stores and returns the accepted version per (user, document)" do
      assert TermsCache.accepted_version(7, "terms_of_service") == nil
      TermsCache.put_accepted(7, "terms_of_service", "2026-05-19")
      assert TermsCache.accepted_version(7, "terms_of_service") == "2026-05-19"
      assert TermsCache.accepted_version(7, "privacy_policy") == nil
    end

    test "put_accepted overwrites with a newer version" do
      TermsCache.put_accepted(8, "terms_of_service", "2026-05-19")
      TermsCache.put_accepted(8, "terms_of_service", "2026-06-01")
      assert TermsCache.accepted_version(8, "terms_of_service") == "2026-06-01"
    end
  end

  describe ":redis backend" do
    setup do
      start_supervised!(Engram.Cache.FakeRedix)

      Application.put_env(:engram, Engram.Cache,
        backend: :redis,
        redis_impl: Engram.Cache.FakeRedix
      )

      :ok
    end

    test "stores and returns the accepted version through the shared store" do
      uid = System.unique_integer([:positive])
      assert TermsCache.accepted_version(uid, "terms_of_service") == nil
      TermsCache.put_accepted(uid, "terms_of_service", "2026-05-19")
      assert TermsCache.accepted_version(uid, "terms_of_service") == "2026-05-19"
      assert TermsCache.accepted_version(uid, "privacy_policy") == nil
    end

    test "get on a dead connection fails open to nil" do
      Application.put_env(:engram, Engram.Cache, backend: :redis)

      assert TermsCache.accepted_version(System.unique_integer([:positive]), "terms_of_service") ==
               nil
    end
  end
end
