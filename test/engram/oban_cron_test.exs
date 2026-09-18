defmodule Engram.ObanCronTest do
  @moduledoc """
  The nightly maintenance chain shares one `maintenance` queue (concurrency 2)
  and one database. Two sweeps landing on the same minute contend for both, and
  the symptom — a slow night, a timeout in whichever worker lost — points at the
  worker rather than at the schedule that caused it.

  This does NOT assert global non-overlap: `ReconcileEmbeddings` (`*/15`) and
  `CleanupDeviceAuthWorker` (`0 * * * *`) deliberately share the top of every
  hour and have since long before this test. It asserts the weaker, true thing —
  that each DAILY worker owns its minute outright.
  """
  use ExUnit.Case, async: true

  alias Oban.Cron.Expression

  defp crontab do
    :engram
    |> Application.get_env(Oban)
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Cron, opts} -> Keyword.fetch!(opts, :crontab)
      _ -> nil
    end)
  end

  # Minutes-of-day an expression fires. Only meaningful for entries that run
  # every day; `daily?/1` below keeps us to those.
  defp slots(expr) do
    parsed = Expression.parse!(expr)

    for h <- parsed.hours, m <- parsed.minutes, into: MapSet.new(), do: h * 60 + m
  end

  defp daily?(expr) do
    parsed = Expression.parse!(expr)
    MapSet.size(parsed.hours) == 1 and MapSet.size(parsed.minutes) == 1
  end

  test "every cron entry parses" do
    for {expr, worker} <- crontab() do
      assert %Expression{} = Expression.parse!(expr), "#{inspect(worker)} has a bad expression"
    end
  end

  test "no two daily workers share a minute" do
    dailies = Enum.filter(crontab(), fn {expr, _} -> daily?(expr) end)

    assert length(dailies) > 1, "expected several daily workers; the schedule shape changed"

    collisions =
      dailies
      |> Enum.group_by(fn {expr, _} -> slots(expr) end, fn {_, worker} -> worker end)
      |> Enum.filter(fn {_slot, workers} -> length(workers) > 1 end)

    assert collisions == [],
           "daily workers scheduled on the same minute: #{inspect(collisions)}"
  end

  test "the CRDT bloat sweep does not collide with any other entry" do
    {sweep_expr, _} =
      Enum.find(crontab(), fn {_, worker} -> worker == Engram.Workers.CrdtBloatSweep end)

    sweep = slots(sweep_expr)

    others =
      crontab()
      |> Enum.reject(fn {_, worker} -> worker == Engram.Workers.CrdtBloatSweep end)
      |> Enum.flat_map(fn {expr, worker} ->
        parsed = Expression.parse!(expr)

        # Sub-hourly entries (`*/15`, `0 * * * *`) fire in EVERY hour, so their
        # minutes collide regardless of the hour the sweep picks — compare on
        # minute-of-hour for those, minute-of-day for the rest.
        if MapSet.size(parsed.hours) == 24 do
          for m <- parsed.minutes, h <- 0..23, do: {h * 60 + m, worker}
        else
          for h <- parsed.hours, m <- parsed.minutes, do: {h * 60 + m, worker}
        end
      end)
      |> Enum.filter(fn {slot, _} -> MapSet.member?(sweep, slot) end)

    assert others == [],
           "CrdtBloatSweep (#{sweep_expr}) shares its minute with: #{inspect(others)}"
  end
end
