defmodule Engram.Crypto.DekCacheTest do
  use ExUnit.Case, async: false
  alias Engram.Crypto.DekCache

  setup do
    DekCache.invalidate_all()
    :ok
  end

  @dek :binary.copy(<<0xAA>>, 32)

  test "put + get round-trip" do
    DekCache.put(1, @dek)
    assert {:ok, @dek} = DekCache.get(1)
  end

  test "miss returns :miss" do
    assert :miss = DekCache.get(404)
  end

  test "invalidate removes entry" do
    DekCache.put(1, @dek)
    DekCache.invalidate(1)
    assert :miss = DekCache.get(1)
  end

  test "invalidate_all clears everything" do
    DekCache.put(1, @dek)
    DekCache.put(2, @dek)
    DekCache.invalidate_all()
    assert :miss = DekCache.get(1)
    assert :miss = DekCache.get(2)
  end

  test "entries expire after TTL" do
    DekCache.put(1, @dek, _ttl_ms = 10)
    Process.sleep(25)
    DekCache.sweep_now()
    assert :miss = DekCache.get(1)
  end

  describe "T3.3 / H2 — ETS write protection" do
    @table :engram_dek_cache

    test "ETS table is :protected (foreign-process write raises)" do
      # Pre-fix: table was :public, so any process could `:ets.insert` and
      # poison-replace a victim's DEK. Post-fix: only the DekCache GenServer
      # can write; foreign-process attempts must raise ArgumentError.
      attacker_dek = :binary.copy(<<0xFF>>, 32)
      now = :erlang.system_time(:millisecond)

      assert_raise ArgumentError, fn ->
        :ets.insert(@table, {99_999, attacker_dek, now + 60_000})
      end
    end

    test "ETS table is :protected (foreign-process delete raises)" do
      DekCache.put(1, @dek)

      assert_raise ArgumentError, fn ->
        :ets.delete(@table, 1)
      end

      # Sanity: legitimate API still works.
      assert {:ok, @dek} = DekCache.get(1)
    end

    test "DekCache GenServer process has :sensitive flag set (M9 — exclude from crash dump)" do
      # `process_info(pid, :sensitive)` is not a valid introspection key on
      # current OTP. We round-trip through the GenServer instead: the helper
      # asks the process to read its own flag (process_flag/2 returns the
      # previous value, so toggling true→true is a non-mutating read).
      assert true == DekCache.sensitive_flag?()
    end
  end
end
