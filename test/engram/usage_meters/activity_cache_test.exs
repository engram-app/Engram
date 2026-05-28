defmodule Engram.UsageMeters.ActivityCacheTest do
  use ExUnit.Case, async: false
  alias Engram.UsageMeters.ActivityCache

  @ts ~U[2026-05-27 12:00:00.000000Z]

  setup do
    on_exit(fn -> Application.delete_env(:engram, Engram.Cache) end)
    :ok
  end

  describe ":ets backend (default)" do
    test "put then get round-trips the timestamp" do
      uid = System.unique_integer([:positive])
      assert ActivityCache.get(uid) == :miss
      assert ActivityCache.put(uid, @ts) == :ok
      assert ActivityCache.get(uid) == {:ok, @ts}
    end
  end

  describe ":redis backend" do
    setup do
      start_supervised!(Engram.Cache.FakeRedix)

      Application.put_env(:engram, Engram.Cache,
        backend: :redis,
        redis_impl: Engram.Cache.FakeRedix
      )

      :ok
    end

    test "put then get round-trips the timestamp through the shared store" do
      uid = System.unique_integer([:positive])
      assert ActivityCache.get(uid) == :miss
      assert ActivityCache.put(uid, @ts) == :ok
      assert ActivityCache.get(uid) == {:ok, @ts}
    end

    test "put writes the activity:{id} key with EX = the debounce window" do
      uid = System.unique_integer([:positive])
      assert ActivityCache.put(uid, @ts) == :ok
      ttl = Integer.to_string(ActivityCache.debounce_seconds())

      assert ["SET", "activity:#{uid}", DateTime.to_iso8601(@ts), "EX", ttl] in Engram.Cache.FakeRedix.commands()
    end

    test "a corrupt (non-ISO8601) cached value degrades to :miss + a distinct decode_error signal" do
      uid = System.unique_integer([:positive])
      Engram.Cache.FakeRedix.put_raw("activity:#{uid}", "not-a-timestamp")

      ref = make_ref()
      name = "decode-#{inspect(ref)}"

      :telemetry.attach(
        name,
        [:engram, :cache, :backend_error],
        fn _e, meas, meta, pid -> send(pid, {:degraded, meas, meta}) end,
        self()
      )

      on_exit(fn -> :telemetry.detach(name) end)

      assert ActivityCache.get(uid) == :miss

      assert_receive {:degraded, %{count: 1},
                      %{cache: :activity, op: :get, reason: :decode_error}}
    end

    test "get on a dead connection fails open to :miss" do
      # No connection started + default impl → the façade catches the exit.
      Application.put_env(:engram, Engram.Cache, backend: :redis)
      assert ActivityCache.get(System.unique_integer([:positive])) == :miss
    end
  end
end
