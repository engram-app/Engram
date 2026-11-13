defmodule EngramWeb.RateLimiterTest do
  use ExUnit.Case, async: false
  alias EngramWeb.RateLimiter

  setup do
    Application.put_env(:engram, RateLimiter, backend: :ets)
    RateLimiter.reset_buckets!()
    on_exit(fn -> Application.put_env(:engram, RateLimiter, backend: :ets) end)
    :ok
  end

  # reset_buckets!/0 must hand back a window with room to burst into. Hammer's
  # fix_window is epoch-aligned, so a burst started just before a 10s edge
  # splits and the N+1th request is allowed (two CI reds on 2026-09-11).
  describe "fresh_window_wait_ms/2" do
    test "waits past the edge when it is inside the margin" do
      assert RateLimiter.fresh_window_wait_ms(9_990) == 11
      assert RateLimiter.fresh_window_wait_ms(9_001) == 1_000
      # The observed CI split: 17ms before a 10s edge.
      assert RateLimiter.fresh_window_wait_ms(1_789_000_009_983) == 18
    end

    test "does not wait with a full margin left" do
      assert RateLimiter.fresh_window_wait_ms(9_000) == 0
      assert RateLimiter.fresh_window_wait_ms(0) == 0
      assert RateLimiter.fresh_window_wait_ms(10_000) == 0
      assert RateLimiter.fresh_window_wait_ms(4_321) == 0
    end

    test "a longer burst waits until it fits before the next edge" do
      # 3.5 s left, a 4 s burst: wait past the edge.
      assert RateLimiter.fresh_window_wait_ms(6_500, 4_000) == 3_501
      assert RateLimiter.fresh_window_wait_ms(1_789_000_008_400, 6_000) == 1_601
      # 5 s left: it fits.
      assert RateLimiter.fresh_window_wait_ms(5_000, 4_000) == 0
    end

    test "reset_buckets!/1 returns with the burst's time before the next edge" do
      RateLimiter.reset_buckets!(4_000)
      left = 10_000 - rem(System.system_time(:millisecond), 10_000)
      assert left >= 3_990, "only #{left}ms left in the window after reset"
    end

    test "a burst longer than a window is refused" do
      assert_raise FunctionClauseError, fn -> RateLimiter.reset_buckets!(10_000) end
    end

    test "reset_buckets!/0 returns with at least the margin before the next edge" do
      RateLimiter.reset_buckets!()
      left = 10_000 - rem(System.system_time(:millisecond), 10_000)
      assert left >= 990, "only #{left}ms left in the window after reset"
    end
  end

  test "default backend is :ets" do
    Application.delete_env(:engram, RateLimiter)
    assert RateLimiter.backend() == :ets
  end

  test "hit delegates to the ETS limiter and enforces the limit" do
    key = "rl_test:#{System.unique_integer([:positive])}"
    assert {:allow, 1} = RateLimiter.hit(key, 60_000, 1)
    assert {:deny, _ms} = RateLimiter.hit(key, 60_000, 1)
  end

  test ":distributed_ets backend is dispatched when configured" do
    Application.put_env(:engram, RateLimiter, backend: :distributed_ets)
    assert RateLimiter.backend() == :distributed_ets

    # DistributedETS.Local must already be running (started by the supervisor).
    # In the test environment the application starts the plain ETS backend, so
    # DistributedETS.Local is NOT running — hitting it would crash. We only
    # assert that backend/0 returns the correct atom; the full round-trip is
    # covered by the DistributedETS unit tests in rate_limiter/distributed_ets_test.exs.
  end

  describe "telemetry — [:engram, :rate_limiter, :hit]" do
    # Steady-state allow/deny visibility restored in #687. Emitted at the façade
    # so it covers BOTH backends; tagged with a bounded `purpose` atom (never the
    # user_id / ip / request_path embedded in the bucket key).
    defp attach_hit(ref) do
      test_pid = self()

      :telemetry.attach(
        {__MODULE__, ref},
        [:engram, :rate_limiter, :hit],
        fn _name, meas, meta, _ -> send(test_pid, {:hit, ref, meas, meta}) end,
        nil
      )

      on_exit(fn -> :telemetry.detach({__MODULE__, ref}) end)
    end

    test "a hit under the limit emits :allow tagged with the given purpose" do
      ref = make_ref()
      attach_hit(ref)
      key = "preauth:#{System.unique_integer([:positive])}"

      assert {:allow, 1} = RateLimiter.hit(key, 1000, 2, :preauth)
      assert_receive {:hit, ^ref, %{count: 1}, %{purpose: :preauth, result: :allow}}, 1000
    end

    test "a hit over the limit emits :deny" do
      ref = make_ref()
      attach_hit(ref)
      key = "rps:#{System.unique_integer([:positive])}"

      assert {:allow, 1} = RateLimiter.hit(key, 1000, 1, :api_rps)
      assert {:deny, _retry_ms} = RateLimiter.hit(key, 1000, 1, :api_rps)
      assert_receive {:hit, ^ref, %{count: 1}, %{purpose: :api_rps, result: :deny}}, 1000
    end

    test "purpose defaults to :other when the arg is omitted (hit/3)" do
      ref = make_ref()
      attach_hit(ref)
      key = "misc:#{System.unique_integer([:positive])}"

      assert {:allow, 1} = RateLimiter.hit(key, 1000, 2)
      assert_receive {:hit, ^ref, %{count: 1}, %{purpose: :other, result: :allow}}, 1000
    end
  end

  # The n backfill's free gate: integer remaining, nothing spent. A float
  # limit is refused (it would make a page size or a spend a float).
  describe "peek/3" do
    test "returns the integer remaining without counting a hit" do
      key = "peek:#{System.unique_integer([:positive])}"
      assert RateLimiter.peek(key, 60_000, 10) === 10
      assert {:allow, 3} = RateLimiter.hit(key, 60_000, 10, :other, 3)
      assert RateLimiter.peek(key, 60_000, 10) === 7
      assert RateLimiter.peek(key, 60_000, 10) === 7
      assert RateLimiter.peek(key, 60_000, 2) === 0
    end

    test "refuses a non-integer limit" do
      assert_raise FunctionClauseError, fn -> RateLimiter.peek("peek:f", 60_000, 1000.0) end
    end
  end
end
