defmodule Engram.Test.FakePressure do
  @moduledoc """
  The test reader behind `Engram.Backfill.Throttle.pressure/1`
  (config/test.exs): a fixed reading, no pressure unless a test `set/1`s one.
  A real reading would see other tests' open sandbox transactions.
  `async: false` tests only; `reset/0` in `on_exit`.
  """

  @key {__MODULE__, :reading}
  @calm %{queue_ms: 0, xact_s: 0}

  def set(reading), do: :persistent_term.put(@key, Map.merge(@calm, reading))
  def reset, do: :persistent_term.erase(@key)
  def read(_repo), do: :persistent_term.get(@key, @calm)
end
