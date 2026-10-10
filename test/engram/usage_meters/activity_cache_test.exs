defmodule Engram.UsageMeters.ActivityCacheTest do
  use ExUnit.Case, async: false
  alias Engram.Cache

  @ts ~U[2026-05-27 12:00:00.000000Z]

  test "put then get round-trips the timestamp" do
    uid = System.unique_integer([:positive])
    assert Cache.get(:activity, uid) == :miss
    assert Cache.put(:activity, uid, @ts) == :ok
    assert Cache.get(:activity, uid) == {:ok, @ts}
  end
end
