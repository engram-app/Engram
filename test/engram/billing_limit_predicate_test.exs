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

  # The key is written out at every call site rather than held in `@key`: the
  # `engram.lint.limit_keys` task scans for literal atoms so every use of a
  # limit key is greppable, and a module attribute hides them from it.
  @huge 10_000_000_000

  setup do
    original = Application.get_env(:engram, :limits_enforced, true)
    on_exit(fn -> Application.put_env(:engram, :limits_enforced, original) end)
    :ok
  end

  test "with enforcement OFF the cap never applies and any count passes" do
    Application.put_env(:engram, :limits_enforced, false)
    user = insert(:user)

    refute Billing.limit_enforced?(user, :lifetime_embed_token_cap)

    assert Billing.check_limit(user, :lifetime_embed_token_cap, 0) == :ok
    assert Billing.check_limit(user, :lifetime_embed_token_cap, @huge) == :ok
  end

  test "with enforcement ON the predicate matches whether the count is consulted" do
    Application.put_env(:engram, :limits_enforced, true)
    user = insert(:user)

    if Billing.limit_enforced?(user, :lifetime_embed_token_cap) do
      # A real ceiling: an absurd count MUST be rejected. If this passes, the
      # predicate claimed a cap that check_limit does not actually apply.
      assert Billing.check_limit(user, :lifetime_embed_token_cap, @huge) ==
               {:error, :limit_reached},
             "limit_enforced? said this plan has a ceiling, but check_limit accepted a\n" <>
               "count of #{@huge}. The two disagree about what a cap is."
    else
      # No ceiling: EVERY count must pass. This is the property that makes
      # skipping the measurement safe.
      assert Billing.check_limit(user, :lifetime_embed_token_cap, 0) == :ok

      assert Billing.check_limit(user, :lifetime_embed_token_cap, @huge) == :ok,
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

  # `cap/2` is the third encoding of "what counts as unlimited" — the one every
  # caller that wants a NUMBER goes through. Before it existed, eight modules
  # decoded the sentinels privately and disagreed: `Engram.Accounts.Export`'s
  # copy passed `-1` through as a real ceiling, so an override meaning
  # "unlimited exports" refused every export. Pin the same safety property here
  # so a future edit cannot re-open that gap by touching one of the three.
  test "cap/2, limit_enforced?/2 and check_limit/3 agree on every unlimited spelling" do
    Application.put_env(:engram, :limits_enforced, true)

    # `-1` — the operator-override sentinel. This is the spelling that bit:
    # `Engram.Accounts.Export`'s private decoder passed it through as a real
    # ceiling, so an override meaning "unlimited exports" refused every export.
    overridden = insert(:user)

    Repo.insert!(
      %Engram.Billing.UserLimitOverride{
        id: Ecto.UUID.generate(),
        user_id: overridden.id,
        key: "lifetime_embed_token_cap",
        value: %{"v" => -1},
        reason: "test",
        set_by: "test"
      },
      skip_tenant_check: true
    )

    assert Billing.cap(overridden, :lifetime_embed_token_cap) == nil
    refute Billing.limit_enforced?(overridden, :lifetime_embed_token_cap)
    assert Billing.check_limit(overridden, :lifetime_embed_token_cap, @huge) == :ok

    # `nil` — the catalog's unmetered default. Not reachable as an override
    # value (`effective_limit/2` treats a nil override as a miss and falls
    # through), so use a key that is nil on this user's own tier:
    # `lifetime_embed_token_cap` is unmetered on paid tiers; use an override of
    # nil-equivalent instead. `account_export_rate_per_24h` is nil on Free.
    unmetered = insert(:user)

    assert Billing.cap(unmetered, :account_export_rate_per_24h) == nil
    refute Billing.limit_enforced?(unmetered, :account_export_rate_per_24h)
    assert Billing.check_limit(unmetered, :account_export_rate_per_24h, @huge) == :ok
  end

  test "cap/2 reports enforcement-off as no cap" do
    Application.put_env(:engram, :limits_enforced, false)
    user = insert(:user)

    assert Billing.cap(user, :lifetime_embed_token_cap) == nil
    assert Billing.granted?(user, :reranker_enabled), "enforcement off grants every boolean"
  end
end
