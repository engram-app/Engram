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
end
