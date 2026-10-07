defmodule Engram.DataMigration do
  @moduledoc """
  A self-healing data migration, run by `Engram.Workers.DataMigrationsRunner`
  until a pass finds no work. See `docs/context/data-migrations-ledger.md`.

  `run_pass/0` does (or enqueues) one bounded slice of work and returns
  `:done` ONLY when it found nothing left to do. Anything uncertain (an
  error, a user skipped mid-rotation, jobs still running) is `:more`.
  """
  @callback name() :: String.t()
  @callback version() :: pos_integer()
  @callback run_pass() :: :done | :more
end
