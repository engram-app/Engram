defmodule Engram.Usage.DailyCap.CacheTest do
  use ExUnit.Case, async: false
  alias Engram.Usage.DailyCap.Cache

  test "mark_empty then empty_until returns remaining seconds" do
    Cache.mark_empty(99, "inapp_search", 60)
    assert {:empty, secs} = Cache.empty_until(99, "inapp_search")
    assert secs > 0 and secs <= 60
  end

  test "unknown for never-marked keys" do
    assert :unknown = Cache.empty_until(12_345, "ext_search")
  end

  test "returns :unknown after expiry" do
    Cache.mark_empty(77, "inapp_search", 0)
    assert :unknown = Cache.empty_until(77, "inapp_search")
  end
end
