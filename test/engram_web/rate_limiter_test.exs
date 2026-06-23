defmodule EngramWeb.RateLimiterTest do
  use ExUnit.Case, async: false
  alias EngramWeb.RateLimiter

  setup do
    Application.put_env(:engram, RateLimiter, backend: :ets)
    RateLimiter.reset_buckets!()
    on_exit(fn -> Application.put_env(:engram, RateLimiter, backend: :ets) end)
    :ok
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
end
