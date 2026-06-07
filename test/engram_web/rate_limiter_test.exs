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

  describe "Redis backend start options" do
    alias EngramWeb.RateLimiter.Redis, as: RedisLimiter

    test "start_opts/1 passes :url and TLS-wildcard hostname-match fun through to Redix" do
      # :prefix and :timeout are compile-time `use Hammer` options. Runtime
      # start options must include :url plus :socket_opts carrying the
      # :https-shape hostname match_fun — Erlang's default hostname check
      # is strict literal, which rejects ElastiCache/Valkey wildcard certs
      # (`*.cluster.cache.amazonaws.com`) on connections to leftmost-label
      # hosts like `master.cluster.cache.amazonaws.com`. The match_fun is
      # ignored for plain-tcp `redis://` URLs (no TLS handshake), so passing
      # it unconditionally is safe for selfhost.
      assert [
               url: "redis://localhost:6379",
               socket_opts: [customize_hostname_check: [match_fun: match_fun]]
             ] = RedisLimiter.start_opts("redis://localhost:6379")

      assert is_function(match_fun)
    end

    test "limiter starts under a supervisor with the production opt shape" do
      # Redix connects asynchronously (sync_connect: false), so this validates
      # the option schema without needing a live Redis server.
      opts = RedisLimiter.start_opts("redis://localhost:6379")
      assert {:ok, pid} = start_supervised({RedisLimiter, opts})
      assert is_pid(pid)
    end

    test ":key_prefix is rejected as a runtime start option (regression guard)" do
      # Documents why the prefix had to move to compile-time `use` opts: passing
      # it as a start option crashes the limiter on boot because Redix validates
      # its option schema strictly and has no :key_prefix key.
      Process.flag(:trap_exit, true)

      assert {:error, _reason} =
               start_supervised(
                 {RedisLimiter, [url: "redis://localhost:6379", key_prefix: "engram_rl:"]}
               )
    end
  end
end
