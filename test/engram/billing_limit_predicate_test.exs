defmodule Engram.BillingLimitPredicateTest do
  # `Billing.limit_enforced?/2` exists so a caller can SKIP measuring something
  # expensive when the cap does not apply. `check_limit/3` returns `:ok` for
  # `:unlimited`, `nil` and `-1` without ever reading `current_count`, so any
  # caller that computes a count first has done that work for nothing on those
  # plans. On the embed path that was one `usage_meters` aggregate per job for
  # every Starter/Pro user, since the resolver returns `nil` for unmetered.
  #
  # The danger in adding a predicate is drift: two places encoding "what counts
  # as unlimited", diverging later, and the reorder silently skipping a cap that
  # IS enforced. That is a billing bypass, not a perf regression.
  #
  # So this asserts the SAFETY PROPERTY rather than specific plan values:
  #
  #     limit_enforced?(user, key) == false
  #       implies check_limit(user, key, ANY count) == :ok
  #
  # If that holds, not measuring cannot change the answer — which is the entire
  # justification for the reorder. Written to be true in any environment, since
  # `effective_limit/2` short-circuits to `:unlimited` whenever
  # `:limits_enforced` is false and the answer would otherwise depend on config.
  use Engram.DataCase, async: false

  alias Engram.Billing

  @key :lifetime_embed_token_cap
  @huge 10_000_000_000

  setup do
    original = Application.get_env(:engram, :limits_enforced, true)
    on_exit(fn -> Application.put_env(:engram, :limits_enforced, original) end)
    :ok
  end

  test "with enforcement OFF the cap never applies and any count passes" do
    Application.put_env(:engram, :limits_enforced, false)
    user = insert(:user)

    refute Billing.limit_enforced?(user, @key)

    assert Billing.check_limit(user, @key, 0) == :ok
    assert Billing.check_limit(user, @key, @huge) == :ok
  end

  test "with enforcement ON the predicate matches whether the count is consulted" do
    Application.put_env(:engram, :limits_enforced, true)
    user = insert(:user)

    if Billing.limit_enforced?(user, @key) do
      # A real ceiling: an absurd count MUST be rejected. If this passes, the
      # predicate claimed a cap that check_limit does not actually apply.
      assert Billing.check_limit(user, @key, @huge) == {:error, :limit_reached},
             "limit_enforced? said this plan has a ceiling, but check_limit accepted a\n" <>
               "count of #{@huge}. The two disagree about what a cap is."
    else
      # No ceiling: EVERY count must pass. This is the property that makes
      # skipping the measurement safe.
      assert Billing.check_limit(user, @key, 0) == :ok

      assert Billing.check_limit(user, @key, @huge) == :ok,
             "limit_enforced? said there is no cap, so the caller will not measure usage —\n" <>
               "but check_limit rejected a large count. Skipping would bypass a real limit."
    end
  end

  test "an unknown key raises rather than reporting no cap" do
    user = insert(:user)

    assert_raise Engram.Billing.UnknownLimitKey, fn ->
      Billing.limit_enforced?(user, :not_a_real_limit_key)
    end
  end
end
