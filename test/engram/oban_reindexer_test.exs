defmodule Engram.ObanReindexerTest do
  @moduledoc """
  oban_jobs is a queue table: rows live a day, VACUUM never shrinks its
  indexes, and prod held 73 MB of index for 17 MB of rows on 2026-11-03.
  `Oban.Reindexer` rebuilds them daily. It runs `REINDEX INDEX
  CONCURRENTLY` on exactly the names it is given, so a stale list fails every
  run (Oban's default names an index we dropped) and a missing one bloats.
  """
  use Engram.DataCase, async: true

  alias Oban.Cron.Expression

  defp reindexer_opts, do: Engram.Jobs.reindexer()

  test "only nodes that run plugins get the Pruner and Reindexer (web runs none)" do
    assert Engram.Jobs.oban_config(plugins: false) == [plugins: false]
    assert {Oban.Reindexer, reindexer_opts()} in Engram.Jobs.oban_config(plugins: [])[:plugins]
  end

  test "reindexes exactly the indexes oban_jobs has" do
    %{rows: rows} =
      Repo.query!("SELECT indexname FROM pg_indexes WHERE tablename = 'oban_jobs'")

    assert Enum.sort(reindexer_opts()[:indexes]) == rows |> List.flatten() |> Enum.sort()
  end

  test "allows a GIN rebuild minutes, not Oban's 15 s" do
    assert reindexer_opts()[:timeout] >= :timer.minutes(5)
  end

  # Daily (Todd 11-03: weekly is too rare for this churn), inside the
  # 10:00-11:15 UTC heavy window, on a minute no cron
  # entry fires (same rule as ObanCronTest).
  test "runs daily in the off-peak window on a free minute" do
    parsed = Expression.parse!(reindexer_opts()[:schedule])
    assert MapSet.size(parsed.weekdays) == 7 and MapSet.size(parsed.days) == 31
    [hour] = MapSet.to_list(parsed.hours)
    [minute] = MapSet.to_list(parsed.minutes)
    assert (hour * 60 + minute) in (10 * 60)..(11 * 60 + 15)

    for {expr, worker} <- Engram.Test.ObanWorkers.crontab(), expr != "@reboot" do
      cron = Expression.parse!(expr)

      refute hour in cron.hours and minute in cron.minutes,
             "#{inspect(worker)} (#{expr}) fires on the reindexer's minute"
    end
  end

  # Prod's runtime role is engram_app, not the owner; without MAINTAIN every
  # REINDEX fails with "must be owner". The suite runs on Postgres 18.
  test "the runtime role may reindex oban_jobs" do
    assert %{rows: [[true]]} =
             Repo.query!("SELECT has_table_privilege('engram_app', 'oban_jobs', 'MAINTAIN')")
  end

  # A one-shot fillfactor 85 hoped for HOT updates, but every Oban update
  # changes the indexed `state`, so none can be HOT (prod: 3,088 of 8.78M).
  # It only left 15% of every page empty.
  test "oban_jobs keeps the default fillfactor" do
    %{rows: [[options]]} =
      Repo.query!("SELECT reloptions FROM pg_class WHERE oid = 'oban_jobs'::regclass")

    refute Enum.any?(options || [], &String.starts_with?(&1, "fillfactor="))
  end
end
