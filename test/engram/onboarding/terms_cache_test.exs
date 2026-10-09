defmodule Engram.Onboarding.TermsCacheTest do
  use ExUnit.Case, async: false

  alias Engram.Cache

  test "miss until put, scoped per {user, document}" do
    assert Cache.get(:terms, {7, "terms_of_service"}) == :miss
    Cache.put(:terms, {7, "terms_of_service"}, "2026-05-19")
    assert Cache.get(:terms, {7, "terms_of_service"}) == {:ok, "2026-05-19"}
    assert Cache.get(:terms, {7, "privacy_policy"}) == :miss
  end

  test "a later put overwrites (versions only advance)" do
    Cache.put(:terms, {8, "terms_of_service"}, "2026-05-19")
    Cache.put(:terms, {8, "terms_of_service"}, "2026-06-01")
    assert Cache.get(:terms, {8, "terms_of_service"}) == {:ok, "2026-06-01"}
  end
end
