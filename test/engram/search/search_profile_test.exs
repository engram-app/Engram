defmodule Engram.Search.SearchProfileTest do
  use Engram.DataCase, async: true

  alias Engram.Billing.UserLimitOverride
  alias Engram.Search.SearchProfile

  # Mirrors the insert_override/2 pattern from LimitsTest — inserts a
  # user_limit_overrides row directly so no factory-level key restriction
  # blocks new catalog keys. The factory's user_limit_override_factory is
  # keyed to "notes_cap" by default; using Repo.insert! avoids that coupling.
  defp insert_override(user, key, value) do
    Repo.insert!(%UserLimitOverride{
      id: Ecto.UUID.generate(),
      user_id: user.id,
      key: to_string(key),
      value: %{"v" => value},
      reason: "test",
      set_by: "test"
    })
  end

  test "free user (no plan) resolves to the off-by-default profile" do
    # insert_user/0 creates a user with no plan_id → falls through to
    # tier-default resolution (free tier) for all keys.
    # search_diversity default is 30 (= 0.3): MMR is on by default as of the
    # search-diversity-mmr feature branch.
    user = insert_user()
    p = SearchProfile.resolve(user)

    assert p.diversity == 0.3
    assert p.full_precision == false
    assert p.reranker == false
    assert p.candidate_pool == 20
    assert p.query_model == nil
  end

  test "per-user override flows through to the profile, live" do
    user = insert_user()

    insert_override(user, "search_query_model", "voyage-4-large")
    insert_override(user, "search_diversity", 30)

    # OverrideCache has a 60 s TTL; evict so the resolver sees the new rows.
    Engram.Billing.OverrideCache.evict(user.id)

    p = SearchProfile.resolve(user)

    assert p.query_model == "voyage-4-large"
    assert p.diversity == 0.3
  end

  test "a -1 override falls back to the default dial, not a negative one" do
    # `as_int/2` passed any integer through, so the unlimited sentinel became
    # `candidate_pool: -1` and `diversity: -0.01`. Decoding now happens in
    # `Billing.cap/2`, which maps every "no cap" spelling to nil.
    user = insert_user()
    insert_override(user, :search_candidate_pool, -1)
    insert_override(user, :search_diversity, -1)

    profile = SearchProfile.resolve(user)

    assert profile.candidate_pool > 0
    assert profile.diversity == 0.3
  end
end
