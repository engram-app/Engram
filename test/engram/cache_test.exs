defmodule Engram.CacheTest do
  use ExUnit.Case, async: false
  alias Engram.Cache

  # Returns a Redix-style {:error, _} carrying a URL-bearing tuple, so we can
  # prove the bounded reason classifier never forwards the raw (secret-bearing)
  # term into telemetry metadata.
  defmodule LeakyErroringRedix do
    @leak "redis://user:SUPERSECRET@cache:6379"
    def leak, do: @leak
    def command(_cmd), do: {:error, {:auth_failed, @leak}}
  end

  # Raises with the secret in the message — exercises the rescue path; only the
  # exception module (not the message) may reach telemetry.
  defmodule LeakyRaisingRedix do
    @leak "redis://user:SUPERSECRET@cache:6379"
    def leak, do: @leak
    def command(_cmd), do: raise("connection failed for #{@leak}")
  end

  setup do
    start_supervised!(Engram.Cache.FakeRedix)
    on_exit(fn -> Application.delete_env(:engram, Cache) end)
    :ok
  end

  test "default backend is :ets" do
    Application.delete_env(:engram, Cache)
    assert Cache.backend() == :ets
  end

  test "backend/0 reflects configured :redis" do
    Application.put_env(:engram, Cache, backend: :redis)
    assert Cache.backend() == :redis
  end

  describe "redis ops via injected impl" do
    setup do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: Engram.Cache.FakeRedix)
      :ok
    end

    test "set then get round-trips" do
      assert Cache.redis_set(:activity, "k", "v", 60) == :ok
      assert Cache.redis_get(:activity, "k") == {:ok, "v"}
    end

    test "set sends the exact key and EX <ttl> on the wire" do
      assert Cache.redis_set(:terms, "terms:42:terms_of_service", "2026-05-19", 86_400) == :ok

      assert ["SET", "terms:42:terms_of_service", "2026-05-19", "EX", "86400"] in Engram.Cache.FakeRedix.commands()
    end

    test "missing key returns :miss" do
      assert Cache.redis_get(:activity, "absent") == :miss
    end
  end

  describe "fail-open" do
    test "redis_get on a dead connection returns :miss + telemetry tagged cache/op (catch :exit)" do
      # Default impl Engram.Cache.Redix, but no connection process is started.
      Application.put_env(:engram, Cache, backend: :redis)
      attach()
      assert Cache.redis_get(:activity, "k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{cache: :activity, op: :get, reason: reason}}
      assert is_atom(reason)
    end

    test "redis_set on a dead connection returns :ok + telemetry tagged cache/op" do
      Application.put_env(:engram, Cache, backend: :redis)
      attach()
      assert Cache.redis_set(:terms, "k", "v", 60) == :ok
      assert_receive {:cache_degraded, %{count: 1}, %{cache: :terms, op: :set, reason: reason}}
      assert is_atom(reason)
    end

    test "an {:error, {atom, secret}} reply is bounded to the outer atom — no leak" do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: LeakyErroringRedix)
      attach()
      assert Cache.redis_get(:activity, "k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{reason: reason}}
      assert reason == :auth_failed
      # The URL/password must never reach telemetry metadata.
      refute inspect(reason) =~ "SUPERSECRET"
      refute inspect(reason) =~ LeakyErroringRedix.leak()
    end

    test "a raise carrying the secret is bounded to the exception module — no leak" do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: LeakyRaisingRedix)
      attach()
      assert Cache.redis_get(:activity, "k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{reason: reason}}
      assert reason == RuntimeError
      refute inspect(reason) =~ "SUPERSECRET"
    end
  end

  defp attach do
    ref = make_ref()
    name = "cache-degraded-#{inspect(ref)}"

    :telemetry.attach(
      name,
      [:engram, :cache, :backend_error],
      fn _event, meas, meta, pid -> send(pid, {:cache_degraded, meas, meta}) end,
      self()
    )

    on_exit(fn -> :telemetry.detach(name) end)
  end
end
