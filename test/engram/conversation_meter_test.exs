defmodule Engram.ConversationMeterTest do
  use Engram.DataCase, async: false

  alias Engram.ConversationMeter
  alias Engram.Repo
  alias Engram.UsageMeters.Meter

  setup do
    prev = Application.get_env(:engram, :limits_enforced)
    Application.put_env(:engram, :limits_enforced, true)

    on_exit(fn ->
      if is_nil(prev),
        do: Application.delete_env(:engram, :limits_enforced),
        else: Application.put_env(:engram, :limits_enforced, prev)
    end)

    :ok
  end

  defp meter(user_id) do
    Repo.one!(from(m in Meter, where: m.user_id == ^user_id), skip_tenant_check: true)
  end

  describe "tick/1 — Free tier (defaults)" do
    test "first call opens a conversation and counts query #1" do
      user = insert(:user)
      assert :ok = ConversationMeter.tick(user.id)

      m = meter(user.id)
      assert m.conversations_today == 1
      assert m.active_conversation_query_count == 1
      assert m.queries_today == 1
    end

    test "50 queries inside one window stay in one conversation" do
      user = insert(:user)

      Enum.each(1..50, fn _ -> assert :ok = ConversationMeter.tick(user.id) end)

      m = meter(user.id)
      assert m.conversations_today == 1
      assert m.active_conversation_query_count == 50
    end

    test "query 51 force-rotates to a new conversation (per-conv cap)" do
      user = insert(:user)
      Enum.each(1..50, fn _ -> ConversationMeter.tick(user.id) end)

      assert :ok = ConversationMeter.tick(user.id)

      m = meter(user.id)
      assert m.conversations_today == 2
      # Rotation resets to 0, then this query bumps to 1
      assert m.active_conversation_query_count == 1
    end

    test "6th conversation in a day is rate-limited" do
      user = insert(:user)

      # Drive 5 forced rotations: 5 conversations × 50 queries = 250 queries
      Enum.each(1..250, fn _ -> ConversationMeter.tick(user.id) end)

      # Next tick would rotate to 6th conversation, which exceeds Free's
      # ai_conversations_per_day=5.
      assert {:rate_limited, :conversations_per_day} = ConversationMeter.tick(user.id)
    end
  end

  describe "tick/1 — window expiry" do
    test "rotates conversation when 30-min window expires" do
      user = insert(:user)
      ConversationMeter.tick(user.id)

      # Push active_conversation_started_at to 31 minutes ago
      thirty_one_min_ago = DateTime.utc_now() |> DateTime.add(-31 * 60, :second)

      Repo.update_all(
        from(m in Meter, where: m.user_id == ^user.id),
        [set: [active_conversation_started_at: thirty_one_min_ago]],
        skip_tenant_check: true
      )

      assert :ok = ConversationMeter.tick(user.id)

      m = meter(user.id)
      assert m.conversations_today == 2
      assert m.active_conversation_query_count == 1
    end
  end

  describe "tick/1 — paid tier" do
    setup do
      # Pro user — nil cap on per-conv + per-day conversation count;
      # ai_queries_per_day capped at 10_000.
      user = insert(:user)
      insert(:subscription, user: user, tier: "pro", status: "active")
      %{user: user}
    end

    test "Pro user can run 200 queries inside one conversation without rotating",
         %{user: user} do
      Enum.each(1..200, fn _ -> assert :ok = ConversationMeter.tick(user.id) end)

      m = meter(user.id)
      assert m.active_conversation_query_count == 200
      assert m.conversations_today == 1
    end

    test "Pro user is rate-limited at 10_000 queries per day", %{user: user} do
      # Seed the meter row, then force the per-day counter near the cap.
      ConversationMeter.tick(user.id)

      Repo.update_all(
        from(m in Meter, where: m.user_id == ^user.id),
        [
          set: [
            queries_today: 9_999,
            queries_day_key: Date.utc_today(),
            conversations_today: 1,
            conversations_day_key: Date.utc_today(),
            active_conversation_started_at: DateTime.utc_now(),
            active_conversation_query_count: 9_999
          ]
        ],
        skip_tenant_check: true
      )

      # 10_000th query — accepted (10k cap, < not <=)
      assert :ok = ConversationMeter.tick(user.id)
      # 10_001st — rejected
      assert {:rate_limited, :queries_per_day} = ConversationMeter.tick(user.id)
    end
  end

  describe "tick/1 — day rollover" do
    test "counters reset when usage_meters day_key rolls forward" do
      user = insert(:user)
      ConversationMeter.tick(user.id)

      yesterday = Date.utc_today() |> Date.add(-1)

      Repo.update_all(
        from(m in Meter, where: m.user_id == ^user.id),
        [
          set: [
            conversations_today: 5,
            conversations_day_key: yesterday,
            queries_today: 250,
            queries_day_key: yesterday
          ]
        ],
        skip_tenant_check: true
      )

      assert :ok = ConversationMeter.tick(user.id)

      m = meter(user.id)
      # Yesterday's counters reset; today opens fresh.
      assert m.conversations_today == 1
      assert m.queries_today == 1
      assert m.conversations_day_key == Date.utc_today()
    end
  end
end
