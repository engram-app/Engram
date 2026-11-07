defmodule Engram.DataMigration do
  @moduledoc """
  A self-healing data migration, run by `Engram.Workers.DataMigrationsRunner`
  until a pass finds no work. See `docs/context/data-migrations-ledger.md`.

  `run_pass/0` does (or enqueues) one bounded slice of work and returns
  `:done` ONLY when it found nothing left to do. Anything uncertain (an
  error, a user skipped mid-rotation, jobs still running) is `:more`.
  `{:more, detail}` is the same, with a keyword list of what it found (e.g.
  `users: 3`) that the runner adds to its log lines.
  """
  @callback name() :: String.t()
  @callback version() :: pos_integer()
  @callback run_pass() :: :done | :more | {:more, keyword()}

  @doc """
  Optional, default `true`. A disabled migration is skipped entirely by the
  runner: no pass, its ledger row is neither opened, alerted on nor marked done.
  """
  @callback enabled?() :: boolean()

  @doc """
  Optional, default `false`. When `true`, the runner re-runs this migration's
  pass once a day even after it is done, and reopens it if the pass finds
  work again (rows written by an older node, or while it was disabled).
  """
  @callback reverify?() :: boolean()

  @optional_callbacks enabled?: 0, reverify?: 0

  @stats {__MODULE__, :pass_stats}
  @max_walks 20

  @doc """
  Records one `IdWindows.heal_pass/4` walk of the current pass (`walk`,
  `fixed`, `left`, `hit_budget`) for the runner's per-pass summary line
  (`Engram.Workers.DataMigrationsRunner`). Process-local, newest
  #{@max_walks} kept, so a long-lived caller outside the runner never grows it.
  """
  @spec record_walk(map()) :: :ok
  def record_walk(walk) do
    stats = Process.get(@stats, %{})
    walks = Enum.take([walk | Map.get(stats, :walks, [])], @max_walks)
    Process.put(@stats, Map.put(stats, :walks, walks))
    :ok
  end

  @doc """
  Adds `fields` (counts and table names, never ids or content) to the
  current pass's summary line, e.g. `FileTimes`' open and clean table sets,
  or `blocked:` with the reason a pass walked nothing.
  """
  @spec report(keyword()) :: :ok
  def report(fields) do
    Process.put(@stats, Map.merge(Process.get(@stats, %{}), Map.new(fields)))
    :ok
  end

  @doc false
  # The runner's: what this process recorded since the last call.
  @spec take_stats() :: map()
  def take_stats, do: Process.delete(@stats) || %{}

  @doc """
  Metadata for a data migration's `:info` progress line (rows repaired,
  blocked, waiting for the fleet): category `:data`, shipped to Loki
  (`Engram.Logger.Metadata.ship_to_loki/1`). `:data` is not an
  `:info`-to-Loki category (volume), so without this the one signal that a
  backfill is moving (or stuck) never leaves the node. Every such line goes
  through here; warnings ship by level already.
  """
  @spec progress_metadata(keyword()) :: keyword()
  def progress_metadata(fields),
    do:
      Engram.Logger.Metadata.with_category(:info, :data, fields)
      |> Engram.Logger.Metadata.ship_to_loki()
end
