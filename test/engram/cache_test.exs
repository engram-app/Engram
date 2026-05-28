defmodule Engram.CacheTest do
  use ExUnit.Case, async: false
  alias Engram.Cache

  # Returns a Redix-style {:error, _} so we exercise the explicit error branch
  # (distinct from the dead-connection :exit path).
  defmodule ErroringRedix do
    def command(_cmd), do: {:error, %Redix.ConnectionError{reason: :closed}}
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
      assert Cache.redis_set("k", "v", 60) == :ok
      assert Cache.redis_get("k") == {:ok, "v"}
    end

    test "missing key returns :miss" do
      assert Cache.redis_get("absent") == :miss
    end
  end

  describe "fail-open" do
    test "redis_get on a dead connection returns :miss + telemetry (catch :exit)" do
      # Default impl Engram.Cache.Redix, but no connection process is started.
      Application.put_env(:engram, Cache, backend: :redis)
      attach()
      assert Cache.redis_get("k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{reason: reason}}
      assert is_atom(reason)
    end

    test "redis_set on a dead connection returns :ok + telemetry" do
      Application.put_env(:engram, Cache, backend: :redis)
      attach()
      assert Cache.redis_set("k", "v", 60) == :ok
      assert_receive {:cache_degraded, %{count: 1}, %{reason: reason}}
      assert is_atom(reason)
    end

    test "redis_get on an {:error, _} reply returns :miss + bounded telemetry reason" do
      Application.put_env(:engram, Cache, backend: :redis, redis_impl: ErroringRedix)
      attach()
      assert Cache.redis_get("k") == :miss
      assert_receive {:cache_degraded, %{count: 1}, %{reason: Redix.ConnectionError}}
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
