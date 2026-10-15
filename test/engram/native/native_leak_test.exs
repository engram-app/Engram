defmodule Engram.NativeLeakTest do
  # async: false — reads the process-wide native heap counter.
  use ExUnit.Case, async: false

  alias Engram.NativeLeak

  # Each new note put into a name index keeps native memory for as long as
  # the index lives: a native-heap allocation the test controls.
  setup do
    {:ok, index, _} = Engram.Native.name_index_build(:crypto.strong_rand_bytes(32), "", "", [])

    %{
      keep: fn ->
        Engram.Native.name_index_put(index, :crypto.strong_rand_bytes(16), "a.md", "a")
      end
    }
  end

  test "a one-time cache filled after the first calls is not a leak", %{keep: keep} do
    # What the regex crate's match-cache pool and the envelope's zstd
    # contexts do: the first call on a thread no earlier call reached keeps a
    # cache for good. A dirty NIF runs on whichever dirty CPU thread is free,
    # which no warm-up can choose, so that first call can come at any point.
    n = :counters.new(1, [])

    NativeLeak.assert_no_leak(fn ->
      :counters.add(n, 1, 1)
      if :counters.get(n, 1) == 50, do: keep.()
    end)
  end

  test "memory kept on every call fails", %{keep: keep} do
    assert_raise ExUnit.AssertionError, fn -> NativeLeak.assert_no_leak(keep) end
  end

  test "memory kept on every 100th call fails", %{keep: keep} do
    n = :counters.new(1, [])

    assert_raise ExUnit.AssertionError, fn ->
      NativeLeak.assert_no_leak(fn ->
        :counters.add(n, 1, 1)
        if rem(:counters.get(n, 1), 100) == 0, do: keep.()
      end)
    end
  end
end
