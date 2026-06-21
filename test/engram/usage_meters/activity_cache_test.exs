defmodule Engram.UsageMeters.ActivityCacheTest do
  use ExUnit.Case, async: false
  alias Engram.UsageMeters.ActivityCache

  @ts ~U[2026-05-27 12:00:00.000000Z]

  test "put then get round-trips the timestamp" do
    uid = System.unique_integer([:positive])
    assert ActivityCache.get(uid) == :miss
    assert ActivityCache.put(uid, @ts) == :ok
    assert ActivityCache.get(uid) == {:ok, @ts}
  end
end
