defmodule Engram.UsageMetersDayTest do
  # The daily embed ceiling's counter (`UsageMeters.day_take/4`). Sandbox-only:
  # these prove the arithmetic; the cross-connection race is in
  # `usage_meters_day_concurrency_test.exs`.
  use Engram.DataCase, async: true

  alias Engram.UsageMeters

  @ceiling 20_000_000
  @t0 ~U[2027-03-10 12:00:00.000000Z]
  @next_day ~U[2027-03-11 00:00:01.000000Z]

  describe "day_take/4" do
    test "reaching the ceiling exactly is allowed, one token past it is refused" do
      user = insert(:user)
      assert {:ok, @ceiling} = UsageMeters.day_take(user.id, @ceiling, @ceiling, now: @t0)
      assert {:error, :ceiling} = UsageMeters.day_take(user.id, 1, @ceiling, now: @t0)
      assert UsageMeters.day_used(user.id, now: @t0) == @ceiling
    end

    test "a refused take counts nothing, lifetime included" do
      user = insert(:user)
      {:ok, 15} = UsageMeters.day_take(user.id, 15, 20, now: @t0)
      assert {:error, :ceiling} = UsageMeters.day_take(user.id, 6, 20, now: @t0)
      assert UsageMeters.day_used(user.id, now: @t0) == 15
      assert UsageMeters.lifetime_embed_tokens(user.id) == 15
    end

    test "a take larger than the ceiling is refused without a row" do
      user = insert(:user)
      assert {:error, :ceiling} = UsageMeters.day_take(user.id, 21, 20, now: @t0)
      assert UsageMeters.day_used(user.id, now: @t0) == 0
      assert UsageMeters.lifetime_embed_tokens(user.id) == 0
    end

    test "the next UTC day starts from zero" do
      user = insert(:user)
      {:ok, 20} = UsageMeters.day_take(user.id, 20, 20, now: @t0)
      assert UsageMeters.day_used(user.id, now: @next_day) == 0
      assert {:ok, 20} = UsageMeters.day_take(user.id, 20, 20, now: @next_day)
      assert UsageMeters.lifetime_embed_tokens(user.id) == 40
    end

    test "a node still on yesterday never resets a day a peer already rolled" do
      user = insert(:user)
      {:ok, 20} = UsageMeters.day_take(user.id, 20, 20, now: @next_day)
      assert {:error, :ceiling} = UsageMeters.day_take(user.id, 1, 20, now: @t0)
      assert UsageMeters.day_used(user.id, now: @next_day) == 20
    end

    test "a ceiling raised mid-day allows more, one lowered below the spend refuses" do
      user = insert(:user)
      {:ok, 20} = UsageMeters.day_take(user.id, 20, 20, now: @t0)
      assert {:ok, 25} = UsageMeters.day_take(user.id, 5, 30, now: @t0)
      assert {:error, :ceiling} = UsageMeters.day_take(user.id, 1, 10, now: @t0)
    end

    test "a meter row from before the ceiling (no day) starts the day at zero" do
      user = insert(:user)
      _ = UsageMeters.add_embed_tokens(user.id, 1_000)
      assert UsageMeters.day_used(user.id, now: @t0) == 0
      assert {:ok, 20} = UsageMeters.day_take(user.id, 20, 20, now: @t0)
      assert UsageMeters.lifetime_embed_tokens(user.id) == 1_020
    end
  end

  describe "release_embed_tokens/2" do
    test "gives back to today's counter, never below zero" do
      user = insert(:user)
      {:ok, _} = UsageMeters.day_take(user.id, 20, 20)
      :ok = UsageMeters.release_embed_tokens(user.id, 15)
      assert UsageMeters.day_used(user.id) == 5
      :ok = UsageMeters.release_embed_tokens(user.id, 15)
      assert UsageMeters.day_used(user.id) == 0
    end
  end

  describe "day_stats/2" do
    test "the max one user spent today and the users at the ceiling, today only" do
      [a, b, c] = for _ <- 1..3, do: insert(:user)
      {:ok, _} = UsageMeters.day_take(a.id, 20, 20, now: @t0)
      {:ok, _} = UsageMeters.day_take(b.id, 7, 20, now: @t0)
      {:ok, _} = UsageMeters.day_take(c.id, 20, 20, now: DateTime.add(@t0, -1, :day))

      # The sandbox transaction sees only this test's rows.
      assert UsageMeters.day_stats(20, now: @t0) == %{max: 20, over: 1}
      assert UsageMeters.day_stats(21, now: @t0) == %{max: 20, over: 0}
    end
  end
end
