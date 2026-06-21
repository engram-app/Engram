defmodule Engram.Usage.DailyCap.CacheTest do
  use ExUnit.Case, async: false
  alias Engram.Usage.DailyCap.Cache

  # Keys are UUID strings in production (user.id). The ETS table is global and
  # NOT sandboxed, so each test mints a fresh UUID — uniqueness, not a table
  # reset, is what keeps tests isolated.
  defp uid, do: Ecto.UUID.generate()

  test "mark_empty then empty_until returns remaining seconds" do
    u = uid()
    Cache.mark_empty(u, "inapp_search", 60)
    assert {:empty, secs} = Cache.empty_until(u, "inapp_search")
    assert secs > 0 and secs <= 60
  end

  test "unknown for never-marked keys" do
    assert :unknown = Cache.empty_until(uid(), "ext_search")
  end

  test "returns :unknown after expiry" do
    u = uid()
    Cache.mark_empty(u, "inapp_search", 0)
    assert :unknown = Cache.empty_until(u, "inapp_search")
  end
end
