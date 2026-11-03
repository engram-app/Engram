defmodule Engram.JobsOptionsTest do
  @moduledoc """
  `Engram.Jobs` is the one home of job options. Two guards:

    * every unique check carries `queue`, whatever `fields:` a policy narrows
      to. Oban's check is `WHERE state IN (..) AND <one predicate per field>`
      and `(state, queue, ...)` is the only btree it can use; without `queue`
      it seq-scans oban_jobs (prod 2026-11-03: 3.8 s, planner cost 11,016 vs
      904 with the queue).
    * no `unique:` value is written inline anywhere in lib/ but `Engram.Jobs`.
  """
  use Engram.DataCase, async: true

  alias Engram.Billing.Workers.OverrideExpirySweep
  alias Engram.Jobs

  test "a check narrowed to [:worker] is scoped to the job's queue" do
    # Same worker and args parked on another queue: not a duplicate once the
    # check carries `queue`. Without it, the real insert below conflicts.
    {:ok, _elsewhere} = Oban.insert(OverrideExpirySweep.new(%{}, queue: :events))

    {:ok, job} = Oban.insert(OverrideExpirySweep.new(%{}))
    refute job.conflict?

    # Dedup on the job's own queue is unchanged.
    {:ok, again} = Oban.insert(OverrideExpirySweep.new(%{}))
    assert again.conflict?
    assert again.id == job.id
  end

  test "every policy with narrowed fields includes :queue, once" do
    for key <- Jobs.unique_keys(), fields = Jobs.unique(key)[:fields] do
      assert Enum.count(fields, &(&1 == :queue)) == 1, inspect(key)
    end
  end

  test "overrides merge, :none never dedups, an unknown key raises" do
    assert Jobs.unique({Engram.Workers.EmbedNote, :debounced}, period: 90)[:period] == 90
    assert Jobs.unique(:none) == false
    assert_raise KeyError, fn -> Jobs.unique(:no_such_policy) end
  end

  # Inline `unique: [..]`, `unique: false`, `unique: @attr`, `unique: var`.
  # A call to `Engram.Jobs.unique/2` is the only accepted value.
  @inline ~r/(?<![`\w])unique:\s*(?!Engram\.Jobs\.unique\(|Jobs\.unique\()\S/

  test "no unique: option is written outside Engram.Jobs" do
    # lib/mix is out: `engram.index_audit` reports a Postgres index's
    # `unique:` flag, not a job option.
    offenders =
      for path <- Path.wildcard("lib/engram{,_web}/**/*.ex"),
          path != "lib/engram/jobs.ex",
          {line, n} <- path |> File.read!() |> String.split("\n") |> Enum.with_index(1),
          not String.starts_with?(String.trim_leading(line), "#"),
          Regex.match?(@inline, line),
          do: "#{path}:#{n}: #{String.trim(line)}"

    assert offenders == [],
           "put the policy in Engram.Jobs' @unique and call Engram.Jobs.unique/2:\n" <>
             Enum.join(offenders, "\n")
  end
end
