defmodule Engram.Maintenance.PrunePlansTest do
  @moduledoc """
  Every retention prune on `Engram.Maintenance.Prune.batched/3` keeps the plan
  it was written for. The cron reuses a prepared GENERIC plan, and a LIMIT
  bound as a parameter (`limit: ^batch`) can flip that plan to another index:
  AnalyticsEventsPrune lost its BRIN that way (review of #2424). So a prune
  whose plan depends on the LIMIT inlines it as a literal.
  """
  use Engram.DataCase, async: false

  alias Engram.QueryPlan
  alias Engram.QueryRecorder

  defp deletes(fun, table) do
    {_, queries} = QueryRecorder.record(fun)
    me = self()
    for %{sql: "DELETE" <> _ = sql, pid: ^me} <- queries, sql =~ ~s("#{table}"), do: sql
  end

  test "install_pings: the batch LIMIT is a literal" do
    [sql | _] =
      deletes(
        fn -> Engram.Workers.InstallPingsPruner.perform(%Oban.Job{}) end,
        "install_pings"
      )

    refute sql =~ ~r/LIMIT \$\d/i, sql
  end

  # The BRIN plan itself, on realistic rows: AnalyticsEventsBrinPlanTest.
  test "analytics_events: the batch LIMIT is a literal" do
    [sql | _] =
      deletes(
        fn -> Engram.Workers.AnalyticsEventsPrune.perform(%Oban.Job{}) end,
        "analytics_events"
      )

    refute sql =~ ~r/LIMIT \$\d/i, sql
  end

  test "idempotency_keys: the expiry index serves the batch" do
    [sql | _] = deletes(fn -> Engram.Idempotency.prune_expired() end, "idempotency_keys")

    assert QueryPlan.generic_plan(sql, analyze: ["idempotency_keys"], fresh: true) =~
             "idempotency_keys_expires_at_index"
  end
end
