defmodule EngramWeb.RateLimiterTest.RaisingLimiter do
  def hit(_key, _scale, _limit), do: raise("redis boom")
end

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

  test "fail-open: an exiting backend allows the request and emits telemetry (catch :exit path)" do
    Application.put_env(:engram, RateLimiter, backend: :redis)

    ref = make_ref()

    :telemetry.attach(
      "fail-open-exit-#{inspect(ref)}",
      [:engram, :rate_limiter, :backend_error],
      fn _event, meas, meta, pid -> send(pid, {:rl_degraded, meas, meta}) end,
      self()
    )

    assert {:allow, 0} = RateLimiter.hit("rl_fail:#{System.unique_integer()}", 60_000, 1)
    assert_receive {:rl_degraded, %{count: 1}, %{backend: :redis, reason: reason}}
    assert is_atom(reason)

    :telemetry.detach("fail-open-exit-#{inspect(ref)}")
  end

  test "fail-open: a raising backend allows the request and emits telemetry (rescue path)" do
    Application.put_env(:engram, RateLimiter,
      backend: :redis,
      redis_impl: EngramWeb.RateLimiterTest.RaisingLimiter
    )

    ref = make_ref()

    :telemetry.attach(
      "fail-open-raise-#{inspect(ref)}",
      [:engram, :rate_limiter, :backend_error],
      fn _event, meas, meta, pid -> send(pid, {:rl_degraded, meas, meta}) end,
      self()
    )

    assert {:allow, 0} = RateLimiter.hit("rl_raise:#{System.unique_integer()}", 60_000, 1)
    assert_receive {:rl_degraded, %{count: 1}, %{backend: :redis, reason: reason}}
    assert is_atom(reason)

    :telemetry.detach("fail-open-raise-#{inspect(ref)}")
  end
end
