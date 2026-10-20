defmodule Engram.ObanRetentionTest do
  # Guard: no job may rely on Oban keeping finished jobs longer than the Pruner
  # does.
  #
  # Oban's `unique:` default states (`:successful`) include `completed`, so a
  # unique period is only as long as completed rows survive. A worker that asks
  # for 30 days of dedupe while the Pruner deletes completed jobs after one day
  # gets one day, silently. Long-lived dedupe belongs in a real table.
  #
  # Retention is short because every retained row is scanned by the PromEx
  # queue-count poll (`GROUP BY queue, state`), the #1 app statement in prod
  # (2026-10-20 audit: 435k calls, 8.6 ms mean, cost linear in retained rows).
  use ExUnit.Case, async: true

  alias Engram.Test.ObanWorkers

  # Workers whose long unique period is NOT their dedupe, with the thing that is.
  @db_deduped %{
    # `perform/1` sends nothing when `OAuth.prior_connection?/3` finds another
    # token family for the same user and client in the last 30 days. The unique
    # period only collapses a burst of exchanges.
    Engram.Workers.ConnectionCreated => "OAuth.prior_connection?/3",
    # One job per `account_exports` row, enqueued once when the row is created.
    # `account_exports_one_active_per_user` is the dedupe.
    Engram.Workers.AccountExport => "account_exports row"
  }

  @one_day 24 * 3600

  test "the Pruner keeps finished jobs for at most a day" do
    assert pruner_max_age() <= @one_day
  end

  test "no worker's unique period outlives the Pruner unless a table dedupes it" do
    max_age = pruner_max_age()

    offenders =
      for mod <- ObanWorkers.all(),
          unique = Keyword.get(mod.__opts__(), :unique),
          is_list(unique),
          counts_completed?(unique),
          longer_than?(Keyword.get(unique, :period, 60), max_age),
          not Map.has_key?(@db_deduped, mod),
          do: {mod, unique[:period]}

    assert offenders == [],
           "these workers dedupe for longer than the Pruner keeps completed jobs\n" <>
             "(#{max_age}s), so the dedupe silently ends early. Use a DB row, or\n" <>
             "add the worker to @db_deduped with the table that really dedupes it:\n" <>
             inspect(offenders, pretty: true)
  end

  test "every allowlisted worker still asks for a long period (else drop it from the list)" do
    for mod <- Map.keys(@db_deduped) do
      unique = Keyword.fetch!(mod.__opts__(), :unique)
      assert longer_than?(Keyword.get(unique, :period, 60), pruner_max_age()), inspect(mod)
    end
  end

  defp counts_completed?(unique) do
    states = Keyword.get(unique, :states, :successful)
    states = if is_atom(states), do: Oban.Job.unique_states(states), else: states
    :completed in states
  end

  defp longer_than?(:infinity, _max), do: true
  defp longer_than?(period, max) when is_integer(period), do: period > max

  defp pruner_max_age do
    :engram
    |> Application.fetch_env!(Oban)
    |> Keyword.fetch!(:plugins)
    |> Enum.find_value(fn
      {Oban.Plugins.Pruner, opts} -> Keyword.fetch!(opts, :max_age)
      _ -> nil
    end)
  end
end
