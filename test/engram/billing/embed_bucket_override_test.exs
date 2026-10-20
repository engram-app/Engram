defmodule Engram.Billing.EmbedBucketOverrideTest do
  # `lifetime_embed_token_cap` was renamed `embed_token_bucket`. Override rows
  # written under the old name (a raised cap, `-1` for a comped account) must
  # keep applying, and stay editable.
  use Engram.DataCase, async: false

  alias Engram.Billing
  alias Engram.Billing.UserLimitOverride

  setup do
    original = Application.get_env(:engram, :limits_enforced, true)
    Application.put_env(:engram, :limits_enforced, true)
    on_exit(fn -> Application.put_env(:engram, :limits_enforced, original) end)
    :ok
  end

  test "Free gets the 6M default with no override" do
    assert Billing.cap(insert(:user), :embed_token_bucket) == 6_000_000
  end

  test "a raised override sets the bucket capacity" do
    user = insert(:user)

    insert(:user_limit_override,
      user: user,
      key: "embed_token_bucket",
      value: %{"v" => 100_000_000}
    )

    assert Billing.cap(user, :embed_token_bucket) == 100_000_000
  end

  test "a legacy -1 row still removes the bucket" do
    user = insert(:user)
    insert(:user_limit_override, user: user, key: "lifetime_embed_token_cap", value: %{"v" => -1})
    assert Billing.cap(user, :embed_token_bucket) == nil
  end

  test "a legacy raised row still raises it" do
    user = insert(:user)

    insert(:user_limit_override,
      user: user,
      key: "lifetime_embed_token_cap",
      value: %{"v" => 40_000_000}
    )

    assert Billing.cap(user, :embed_token_bucket) == 40_000_000
  end

  test "the new key wins over a legacy row" do
    user = insert(:user)

    insert(:user_limit_override,
      user: user,
      key: "lifetime_embed_token_cap",
      value: %{"v" => 40_000_000}
    )

    insert(:user_limit_override,
      user: user,
      key: "embed_token_bucket",
      value: %{"v" => 9_000_000}
    )

    assert Billing.cap(user, :embed_token_bucket) == 9_000_000
  end

  test "a legacy row stays editable" do
    attrs = %{
      user_id: insert(:user).id,
      key: "lifetime_embed_token_cap",
      value: %{"v" => 1},
      reason: "test",
      set_by: "test"
    }

    assert UserLimitOverride.changeset(%UserLimitOverride{}, attrs).valid?
    refute UserLimitOverride.changeset(%UserLimitOverride{}, %{attrs | key: "nope"}).valid?
  end
end
