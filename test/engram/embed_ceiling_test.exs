defmodule Engram.EmbedCeilingTest do
  use Engram.DataCase, async: true

  alias Engram.EmbedCeiling
  alias Engram.ServiceConfig
  alias Engram.UsageMeters

  defp paid_user do
    user = insert(:user)
    insert(:subscription, user: user, tier: "pro", status: "active")
    Engram.Accounts.get_user_with_subscription(user.id)
  end

  describe "tokens/1" do
    test "a paid user gets the 20M default" do
      assert EmbedCeiling.tokens(paid_user()) == 20_000_000
    end

    test "a Free user (bucket) has none" do
      assert EmbedCeiling.tokens(insert(:user)) == nil
    end

    test "a -1 override and the kill switch lift it" do
      user = paid_user()
      ServiceConfig.put_override(:embed_daily_ceiling, false)
      assert EmbedCeiling.tokens(user) == nil
      ServiceConfig.put_override(:embed_daily_ceiling, true)

      insert(:user_limit_override, user: user, key: "embed_tokens_per_day", value: %{"v" => -1})
      Engram.Billing.OverrideCache.evict(user.id)
      assert EmbedCeiling.tokens(user) == nil
    end
  end

  describe "over?/1" do
    test "true only once today's spend reaches the ceiling" do
      user = paid_user()
      {:ok, _} = UsageMeters.day_take(user.id, 19_999_999, 20_000_000)
      refute EmbedCeiling.over?(user)
      {:ok, _} = UsageMeters.day_take(user.id, 1, 20_000_000)
      assert EmbedCeiling.over?(user)
    end
  end

  describe "resume_at/2" do
    test "the next 00:00 UTC plus a fixed per-user offset under an hour" do
      now = ~U[2027-03-10 23:59:59Z]
      id = Ecto.UUID.generate()
      at = EmbedCeiling.resume_at(id, now)

      assert DateTime.to_date(at) == ~D[2027-03-11]
      assert at.hour == 0
      assert at == EmbedCeiling.resume_at(id, ~U[2027-03-10 00:00:00Z])
    end
  end

  describe "stats/0" do
    test "nil with the kill switch off" do
      ServiceConfig.put_override(:embed_daily_ceiling, false)
      assert EmbedCeiling.stats() == nil
    end

    test "the day's max, its share of the ceiling and users over" do
      user = paid_user()
      {:ok, _} = UsageMeters.day_take(user.id, 10_000_000, 20_000_000)
      assert %{max: 10_000_000, share: 0.5, over: 0} = EmbedCeiling.stats()
    end
  end
end
