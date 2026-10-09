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
end
