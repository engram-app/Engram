defmodule Engram.Abuse.OriginStatsBufferTest do
  # Not async: the QueryRecorder telemetry handler is global and would count
  # other tests' (and the PromEx poller's) queries.
  use Engram.DataCase, async: false

  alias Engram.Abuse.OriginStats

  describe "buffering" do
    test "record/2 issues zero queries" do
      user = insert(:user)

      {_, qs} = Engram.QueryRecorder.record(fn -> OriginStats.record(user.id, "curl/7.81") end)
      assert qs == []
      OriginStats.flush(user.id)
    end

    test "two records then one flush is exactly one query, with the summed count" do
      user = insert(:user)
      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")
      OriginStats.record(user.id, "Engram-Obsidian/0.5.0")

      {_, qs} = Engram.QueryRecorder.record(fn -> OriginStats.flush(user.id) end)
      assert length(qs) == 1
      assert {2, %{"plugin" => 2}} = OriginStats.day_totals(user.id, Date.utc_today())
    end

    test "a second flush adds to the existing row and the buffer is reset" do
      user = insert(:user)
      OriginStats.record(user.id, "curl/7.81")
      OriginStats.flush(user.id)
      OriginStats.record(user.id, "curl/7.81")
      OriginStats.flush(user.id)

      {_, qs} = Engram.QueryRecorder.record(fn -> OriginStats.flush(user.id) end)
      assert qs == []
      assert {2, _} = OriginStats.day_totals(user.id, Date.utc_today())
    end

    test "flush with no counters issues zero queries" do
      user = insert(:user)
      {_, qs} = Engram.QueryRecorder.record(fn -> OriginStats.flush(user.id) end)
      assert qs == []
    end
  end
end
