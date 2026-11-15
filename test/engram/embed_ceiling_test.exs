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
    test "true once less than one chunk (`floor/0`) is left today" do
      user = paid_user()
      {:ok, _} = UsageMeters.day_take(user.id, 20_000_000 - EmbedCeiling.floor(), 20_000_000)
      refute EmbedCeiling.over?(user)
      assert EmbedCeiling.available(user.id, 20_000_000) == EmbedCeiling.floor()
      {:ok, _} = UsageMeters.day_take(user.id, 1, 20_000_000)
      assert EmbedCeiling.over?(user)
    end
  end

  # Unlimited is one rule: the -1 bucket override every staging account has.
  describe "exemptions" do
    test "a -1 embed bucket override lifts the ceiling; without it the user is capped" do
      capped = paid_user()
      exempt = paid_user()
      insert(:user_limit_override, user: exempt, key: "embed_token_bucket", value: %{"v" => -1})
      Engram.Billing.OverrideCache.evict(exempt.id)

      assert EmbedCeiling.tokens(capped) == 20_000_000
      assert EmbedCeiling.tokens(exempt) == nil

      for user <- [capped, exempt] do
        {:ok, _} = UsageMeters.day_take(user.id, 20_000_000, 20_000_000)
      end

      assert EmbedCeiling.over?(capped)
      refute EmbedCeiling.over?(exempt)
    end
  end

  describe "resume_at/2" do
    test "the next 00:00 UTC plus a fixed per-user offset under six hours" do
      now = ~U[2027-03-10 23:59:59Z]
      id = Ecto.UUID.generate()
      at = EmbedCeiling.resume_at(id, now)

      assert DateTime.to_date(at) == ~D[2027-03-11]
      assert at.hour < 6
      # Before today's resume time, today's; from it on, tomorrow's.
      assert EmbedCeiling.resume_at(id, DateTime.add(at, -1)) == at
      assert EmbedCeiling.resume_at(id, at) == DateTime.add(at, 1, :day)
    end
  end

  describe "wake_budget/3" do
    setup do
      user = paid_user()
      today = Date.utc_today()

      before =
        EmbedCeiling.resume_at(
          user.id,
          DateTime.new!(today, ~T[00:00:00], "Etc/UTC") |> DateTime.add(-1)
        )

      %{user: user, resume: before}
    end

    test "a user capped yesterday gets 0 until their resume time, then the new day",
         %{user: user, resume: resume} do
      yesterday = DateTime.add(resume, -1, :day)
      {:ok, _} = UsageMeters.day_take(user.id, 20_000_000, 20_000_000, now: yesterday)

      assert EmbedCeiling.wake_budget(user.id, 20_000_000, DateTime.add(resume, -1)) == 0
      assert EmbedCeiling.wake_budget(user.id, 20_000_000, resume) == 20_000_000
    end

    test "a user not capped yesterday wakes at once, at midnight", %{user: user, resume: resume} do
      midnight = DateTime.new!(DateTime.to_date(resume), ~T[00:00:00], "Etc/UTC")
      {:ok, _} = UsageMeters.day_take(user.id, 1_000, 20_000_000, now: DateTime.add(midnight, -1))
      assert EmbedCeiling.wake_budget(user.id, 20_000_000, midnight) == 20_000_000
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
