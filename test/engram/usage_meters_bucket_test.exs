defmodule Engram.UsageMetersBucketTest do
  use Engram.DataCase, async: true

  alias Engram.UsageMeters

  @cap 6_000_000
  @year 31_536_000
  @t0 ~U[2027-01-01 00:00:00.000000Z]

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  describe "bucket_take/4" do
    test "a new user takes the whole bucket at once, then the next token is refused" do
      user = insert(:user)
      assert {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: @t0)
      assert {:error, :bucket_empty} = UsageMeters.bucket_take(user.id, 1, @cap, now: @t0)
    end

    test "a take larger than the capacity is refused without touching the row" do
      user = insert(:user)
      assert {:error, :bucket_empty} = UsageMeters.bucket_take(user.id, @cap + 1, @cap, now: @t0)
      assert UsageMeters.bucket_available(user.id, @cap, now: @t0) == @cap
    end

    test "refills continuously: 30.4 days restores about 500k" do
      user = insert(:user)
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: @t0)

      available = UsageMeters.bucket_available(user.id, @cap, now: at(round(30.4 * 86_400)))
      assert_in_delta available, 500_000, 5_000
    end

    test "half a day restores about 8.2k" do
      user = insert(:user)
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: @t0)
      assert_in_delta UsageMeters.bucket_available(user.id, @cap, now: at(43_200)), 8_219, 2
    end

    test "never refills above capacity" do
      user = insert(:user)
      {:ok, _} = UsageMeters.bucket_take(user.id, 10, @cap, now: @t0)
      assert UsageMeters.bucket_available(user.id, @cap, now: at(5 * @year)) == @cap
      assert {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: at(5 * @year))
    end

    test "refill is per elapsed second, so a leap day counts like any other day" do
      user = insert(:user)
      feb28 = ~U[2028-02-28 00:00:00.000000Z]
      mar1 = ~U[2028-03-01 00:00:00.000000Z]
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: feb28)

      # 2028 is a leap year: Feb 28 -> Mar 1 is two days, not one.
      two_days = 2 * 86_400 * @cap / @year
      assert_in_delta UsageMeters.bucket_available(user.id, @cap, now: mar1), two_days, 1
    end

    test "a full year after emptying, the bucket is full again (leap year included)" do
      user = insert(:user)
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: ~U[2028-01-01 00:00:00Z])

      # 366 days > the 365-day refill period: full, clamped at capacity.
      assert UsageMeters.bucket_available(user.id, @cap, now: ~U[2029-01-01 00:00:00Z]) == @cap
    end

    test "a clock that moved backward refills nothing and does not rewind the stamp" do
      user = insert(:user)
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: at(1000))
      assert {:error, :bucket_empty} = UsageMeters.bucket_take(user.id, 1, @cap, now: @t0)
      assert UsageMeters.bucket_available(user.id, @cap, now: @t0) == 0
      # Refill counts from the latest stamp, not the skewed earlier one.
      assert_in_delta UsageMeters.bucket_available(user.id, @cap, now: at(1000 + 86_400)),
                      86_400 * @cap / @year,
                      1
    end

    test "small frequent takes do not lose the fractional refill" do
      user = insert(:user)
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: @t0)

      # ~1.9 tokens refill per 10 s. An integer bucket re-stamped on every take
      # would floor each refill to 1, spend it, and sit at 0 forever.
      for i <- 1..100, do: {:ok, _} = UsageMeters.bucket_take(user.id, 1, @cap, now: at(10 * i))

      assert_in_delta UsageMeters.bucket_available(user.id, @cap, now: at(1000)),
                      1000 * @cap / @year - 100,
                      1
    end

    test "a raised override is a bigger bucket" do
      user = insert(:user)
      assert {:error, :bucket_empty} = UsageMeters.bucket_take(user.id, 7_000_000, @cap, now: @t0)

      assert {:ok, 93_000_000} =
               UsageMeters.bucket_take(user.id, 7_000_000, 100_000_000, now: @t0)
    end

    test "every successful take still counts toward the lifetime meter" do
      user = insert(:user)
      {:ok, _} = UsageMeters.bucket_take(user.id, 1500, @cap, now: @t0)
      {:error, :bucket_empty} = UsageMeters.bucket_take(user.id, @cap, @cap, now: @t0)
      assert UsageMeters.lifetime_embed_tokens(user.id) == 1500
    end

    test "the carry-over migration starts existing users on what the lifetime cap left" do
      Code.require_file("priv/repo/migrations/20261021150002_carry_over_embed_bucket.exs")
      migration = Engram.Repo.Migrations.CarryOverEmbedBucket

      heavy = insert(:user)
      light = insert(:user)
      over = insert(:user)
      in_use = insert(:user)
      UsageMeters.add_embed_tokens(heavy.id, 17_000_000)
      UsageMeters.add_embed_tokens(light.id, 1_000_000)
      UsageMeters.add_embed_tokens(over.id, 25_000_000)
      {:ok, _} = UsageMeters.bucket_take(in_use.id, 100, @cap, now: @t0)

      Engram.Repo.query!(migration.sql())

      now = DateTime.utc_now()
      assert_in_delta UsageMeters.bucket_available(heavy.id, @cap, now: now), 3_000_000, 5
      assert_in_delta UsageMeters.bucket_available(light.id, @cap, now: now), @cap, 5
      # Over the old cap: empty, refilling from now.
      assert UsageMeters.bucket_available(over.id, @cap, now: now) < 5
      # A bucket already in use is left alone.
      assert UsageMeters.bucket_available(in_use.id, @cap, now: @t0) == @cap - 100
      # A user with no meter row has never embedded and starts full.
      assert UsageMeters.bucket_available(insert(:user).id, @cap) == @cap
    end
  end

  describe "release_embed_tokens/2" do
    test "gives a failed embed's tokens back to the bucket" do
      user = insert(:user)
      {:ok, 0} = UsageMeters.bucket_take(user.id, @cap, @cap, now: @t0)
      :ok = UsageMeters.release_embed_tokens(user.id, 2_000)
      assert UsageMeters.bucket_available(user.id, @cap, now: @t0) == 2_000
      assert UsageMeters.lifetime_embed_tokens(user.id) == @cap - 2_000
    end
  end

  describe "bucket_full_at/3" do
    test "nil when already full" do
      assert UsageMeters.bucket_full_at(@cap, @cap, @t0) == nil
    end

    test "an empty bucket is full one refill period later" do
      assert UsageMeters.bucket_full_at(0, @cap, @t0) == at(@year)
    end

    test "half full is half a period away" do
      assert UsageMeters.bucket_full_at(div(@cap, 2), @cap, @t0) == at(div(@year, 2))
    end
  end

  describe "bucket_ready_at/4" do
    test "a backlog bigger than the bucket drains at the refill rate, past the full date" do
      # 10M parked behind an empty 6M bucket: the wake keeps draining as it
      # refills, so the last note fits 10/6 of a year out, not when it is full.
      assert UsageMeters.bucket_ready_at(0, 10_000_000, @cap, @t0) ==
               at(div(10_000_000 * @year, @cap))
    end

    test "counts what the bucket already holds" do
      assert UsageMeters.bucket_ready_at(1_000_000, 4_000_000, @cap, @t0) == at(div(@year, 2))
    end

    test "nil when the backlog fits now, or the bucket never refills" do
      assert UsageMeters.bucket_ready_at(500, 500, @cap, @t0) == nil
      assert UsageMeters.bucket_ready_at(0, 500, 0, @t0) == nil
    end
  end
end
