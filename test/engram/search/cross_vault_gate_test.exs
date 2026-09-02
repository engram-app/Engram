defmodule Engram.Search.CrossVaultGateTest do
  @moduledoc """
  Pins the `cross_vault_search` gate and its ONE deliberate bypass.

  This key spent time in `LimitEnforcementTest`'s `@unenforced` list as
  "legacy UX flag; no per-request gate point yet". That went stale —
  `Engram.Search.cross_vault_allowed/2` gates every REST search — and nothing
  failed when it did, because no test drove the gate. Two things are pinned
  here so the exemption cannot come back by drift:

    1. A Free user asking for cross-vault search over REST is refused.
    2. MCP passing `allow_cross_vault: true` is NOT refused — multi-vault
       search is the MCP default on every tier (product decision 2026-07-10,
       see `Engram.MCP.Handlers.handle("search_notes", ...)`).

  (2) is the load-bearing half. It is an intentional hole in a billing gate,
  and an intentional hole with no test looks exactly like an accidental one to
  whoever reads it next.
  """
  use Engram.DataCase, async: true

  import Engram.Factory

  alias Engram.Search

  describe "cross_vault_search gate" do
    test "a Free user is refused cross-vault search on the REST path" do
      user = insert(:user)

      assert {:error, :feature_not_available} =
               Search.search(user, nil, "anything", cross_vault: true)
    end

    test "an entitled user is not refused" do
      user = insert(:user)

      insert(:user_limit_override,
        user: user,
        key: "cross_vault_search",
        value: %{"v" => true}
      )

      # Only the gate is under test — an entitled user gets past it. Whatever
      # the search itself returns (including an empty list for a user with no
      # notes) is not `:feature_not_available`.
      refute Search.search(user, nil, "anything", cross_vault: true) ==
               {:error, :feature_not_available}
    end

    test "allow_cross_vault bypasses the gate for a Free user (MCP default)" do
      user = insert(:user)

      refute Search.search(user, nil, "anything",
               cross_vault: true,
               allow_cross_vault: true
             ) == {:error, :feature_not_available}
    end
  end

  test "an unentitled cross-vault search does not spend a search token" do
    # Ordering regression. The budget used to be spent before the cross-vault
    # entitlement check, so a user refused for lacking `cross_vault_search`
    # still paid a token for a search they never got. Unreachable on stock
    # tiers (Free has one vault; Starter has no search cap), which is exactly
    # why it needs a test — an override on either key makes it live.
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "ai_searches_per_day", value: %{"v" => 1})
    EngramWeb.RateLimiter.reset_buckets!()

    assert {:error, _} = Search.search(user, nil, "anything", cross_vault: true)

    # The token survived: a normal search still works.
    refute match?({:error, :search_cap_exceeded, _}, Search.search(user, nil, "anything", []))
  end
end
