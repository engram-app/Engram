defmodule Engram.Billing.Workers.OverrideExpirySweepTest do
  use Engram.DataCase, async: false
  use Oban.Testing, repo: Engram.Repo

  alias Engram.Billing.UserLimitOverride
  alias Engram.Billing.Workers.OverrideExpirySweep
  alias Engram.Repo

  defp insert_override(user, expires_at) do
    Repo.insert!(%UserLimitOverride{
      user_id: user.id,
      key: "notes_cap",
      value: %{"v" => 100},
      reason: "test",
      set_by: "test",
      expires_at: expires_at
    })
  end

  describe "perform/1" do
    test "deletes rows where expires_at <= now()" do
      user1 = insert(:user)
      user2 = insert(:user)

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      expired = insert_override(user1, past)
      not_expired = insert_override(user2, future)

      assert :ok = perform_job(OverrideExpirySweep, %{})

      refute Repo.get(UserLimitOverride, expired.id)
      assert Repo.get(UserLimitOverride, not_expired.id)
    end

    test "ignores rows with expires_at IS NULL" do
      user = insert(:user)

      permanent =
        Repo.insert!(%UserLimitOverride{
          user_id: user.id,
          key: "notes_cap",
          value: %{"v" => 100},
          reason: "test",
          set_by: "test"
        })

      assert :ok = perform_job(OverrideExpirySweep, %{})

      assert Repo.get(UserLimitOverride, permanent.id)
    end

    test "emits telemetry event with count" do
      user = insert(:user)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      insert_override(user, past)

      :telemetry_test.attach_event_handlers(self(), [
        [:engram, :billing, :overrides, :expired]
      ])

      assert :ok = perform_job(OverrideExpirySweep, %{})

      assert_received {[:engram, :billing, :overrides, :expired], _ref, %{count: 1}, %{}}
    end

    test "emits count=0 telemetry on empty table" do
      :telemetry_test.attach_event_handlers(self(), [
        [:engram, :billing, :overrides, :expired]
      ])

      assert :ok = perform_job(OverrideExpirySweep, %{})

      assert_received {[:engram, :billing, :overrides, :expired], _ref, %{count: 0}, %{}}
    end

    test "is idempotent — second run with no new expired rows deletes 0" do
      user = insert(:user)
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(3600, :second) |> DateTime.truncate(:second)

      insert_override(user, past)
      survivor = insert_override(insert(:user), future)

      :telemetry_test.attach_event_handlers(self(), [
        [:engram, :billing, :overrides, :expired]
      ])

      assert :ok = perform_job(OverrideExpirySweep, %{})
      assert_received {[:engram, :billing, :overrides, :expired], _ref, %{count: 1}, %{}}

      assert :ok = perform_job(OverrideExpirySweep, %{})
      assert_received {[:engram, :billing, :overrides, :expired], _ref, %{count: 0}, %{}}

      assert Repo.get(UserLimitOverride, survivor.id)
    end

    test "flushes the override cache when it deletes rows" do
      # Cache a miss for one user, then grant them an override. The sweep
      # deleting any expired row (another user's here) must evict_all so
      # grants/deletions become visible without waiting out the TTL.
      user = insert(:user)
      on_exit(fn -> Engram.Billing.OverrideCache.evict_all() end)

      default = Engram.Billing.effective_limit(user, :notes_cap)

      Repo.insert!(%UserLimitOverride{
        user_id: user.id,
        key: "notes_cap",
        value: %{"v" => 123_456},
        reason: "test",
        set_by: "test"
      })

      # Miss is cached — still the default.
      assert Engram.Billing.effective_limit(user, :notes_cap) == default

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      insert_override(insert(:user), past)

      assert :ok = perform_job(OverrideExpirySweep, %{})

      assert Engram.Billing.effective_limit(user, :notes_cap) == 123_456
    end

    test "handles mixed past + future + NULL in a single sweep" do
      now = DateTime.utc_now(:second)
      past = DateTime.add(now, -3600, :second)
      future = DateTime.add(now, 3600, :second)

      expired = insert_override(insert(:user), past)
      future_row = insert_override(insert(:user), future)

      permanent =
        Repo.insert!(%UserLimitOverride{
          user_id: insert(:user).id,
          key: "notes_cap",
          value: %{"v" => 100},
          reason: "test",
          set_by: "test"
        })

      :telemetry_test.attach_event_handlers(self(), [
        [:engram, :billing, :overrides, :expired]
      ])

      assert :ok = perform_job(OverrideExpirySweep, %{})
      assert_received {[:engram, :billing, :overrides, :expired], _ref, %{count: 1}, %{}}

      refute Repo.get(UserLimitOverride, expired.id)
      assert Repo.get(UserLimitOverride, future_row.id)
      assert Repo.get(UserLimitOverride, permanent.id)
    end
  end
end
