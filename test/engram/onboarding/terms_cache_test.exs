defmodule Engram.Onboarding.TermsCacheTest do
  use ExUnit.Case, async: false
  alias Engram.Onboarding.TermsCache

  setup do
    :ok
  end

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
