defmodule Engram.AnalyticsEventsBrinPlanTest do
  # Guard: the time-range reads of analytics_events (the hourly retention
  # sweep, the daily snapshot's rollups) are served by the BRIN index on
  # inserted_at that replaced its btree. The table is append-only and rows
  # arrive in time order, so a BRIN summary per block range answers the same
  # ranges for about nothing per row, where the btree carried about 31 bytes
  # per event.
  use Engram.DataCase, async: true

  alias Engram.Analytics.Event
  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  setup do
    user = insert(:user)
    now = DateTime.utc_now()

    rows =
      for n <- 1..2_000 do
        %{
          user_id: user.id,
          event: "search_performed",
          props: %{},
          inserted_at: DateTime.add(now, -n * 60, :second)
        }
      end

    Repo.insert_all(Event, rows)
    :ok
  end

  test "the retention sweep's batch uses the BRIN index" do
    {_, queries} =
      QueryRecorder.record(fn ->
        Engram.Workers.AnalyticsEventsPrune.perform(%Oban.Job{})
      end)

    [sql | _] = QueryPlan.reading(queries, "analytics_events")

    assert QueryPlan.generic_plan(sql, analyze: ["analytics_events"]) =~
             "analytics_events_inserted_at_brin"
  end

  test "the btree on inserted_at is gone" do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'analytics_events'")

    refute ["analytics_events_inserted_at_index"] in rows
  end
end
