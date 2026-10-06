defmodule Engram.ObanCronTest do
  @moduledoc """
  The crons share the `maintenance` queue (concurrency 2) and one database.
  Two landing on the same minute contend for both, and the symptom — a slow
  run, a timeout in whichever worker lost — points at the worker rather than at
  the schedule that caused it. So no two entries share any minute of the day.
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

  # Every minute-of-day an expression can fire. `*/15` and `0 * * * *` expand to
  # all 24 hours here, which is what makes a plain set intersection the right
  # collision test for sub-hourly entries as well as daily ones.
  defp slots(expr) do
    parsed = Expression.parse!(expr)

    for h <- parsed.hours, m <- parsed.minutes, into: MapSet.new(), do: h * 60 + m
  end

  # Runs at exactly one minute-of-day, on every day. The day/weekday check
  # matters: `0 5 * * 0` also has one hour and one minute but fires weekly, and
  # treating it as daily would fail the collision assertion below against a
  # daily job it only meets on Sundays.
  defp daily?(expr) do
    parsed = Expression.parse!(expr)

    MapSet.size(parsed.hours) == 1 and MapSet.size(parsed.minutes) == 1 and
      MapSet.size(parsed.days) == 31 and MapSet.size(parsed.weekdays) == 7 and
      MapSet.size(parsed.months) == 12
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

  test "no two entries share any minute of the day" do
    collisions =
      for {expr_a, worker_a} <- crontab(),
          {expr_b, worker_b} <- crontab(),
          worker_a < worker_b,
          shared = MapSet.intersection(slots(expr_a), slots(expr_b)),
          MapSet.size(shared) > 0,
          do: {worker_a, worker_b, shared |> Enum.min() |> then(&{div(&1, 60), rem(&1, 60)})}

    assert collisions == [],
           "crons sharing a minute (first {hour, minute}): #{inspect(collisions)}"
  end
end
