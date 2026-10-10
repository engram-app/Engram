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

    test "record/2 drops the count instead of raising when the buffer is down" do
      user = insert(:user)
      :ok = Supervisor.terminate_child(Engram.Supervisor, OriginStats.Buffer)
      on_exit(fn -> Supervisor.restart_child(Engram.Supervisor, OriginStats.Buffer) end)

      assert :ok = OriginStats.record(user.id, "curl/7.81")
    end

    test "flush with no counters issues zero queries" do
      user = insert(:user)
      {_, qs} = Engram.QueryRecorder.record(fn -> OriginStats.flush(user.id) end)
      assert qs == []
    end
  end

  test "a deleted user's counts never drop a live user's counts" do
    live = insert(:user)
    dead = insert(:user)
    OriginStats.record(live.id, "curl/7.81")
    OriginStats.record(live.id, "curl/7.81")
    OriginStats.record(dead.id, "curl/7.81")
    Engram.Repo.delete!(dead, skip_tenant_check: true)

    {_, qs} = Engram.QueryRecorder.record(fn -> flush_both(live, dead) end)
    assert length(qs) == 1
    assert {2, _} = OriginStats.day_totals(live.id, Date.utc_today())
  end

  test "different day keys flush to separate rows" do
    user = insert(:user)
    OriginStats.record(user.id, "curl/7.81")
    yesterday = Date.add(Date.utc_today(), -1)
    key = {yesterday, user.id, "unknown"}
    :ets.insert(OriginStats.table(), {key, 3})
    OriginStats.flush(user.id)

    assert {1, _} = OriginStats.day_totals(user.id, Date.utc_today())
    assert {3, _} = OriginStats.day_totals(user.id, yesterday)
  end

  # flush/1 is per user in tests; both users' keys go through one :all-style call.
  defp flush_both(live, dead) do
    OriginStats.flush([live.id, dead.id])
  end
end
