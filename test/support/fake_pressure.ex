defmodule Engram.Test.FakePressure do
  @moduledoc """
  The test reader behind `Engram.Backfill.Throttle.pressure/0`
  (config/test.exs): a fixed reading, no pressure unless a test `set/1`s one
  (or `fail/0`s the probe).
  A real reading would see other tests' open sandbox transactions.
  `async: false` tests only; `reset/0` in `on_exit`.
  """

  @key {__MODULE__, :reading}
  @calm %{queue_ms: 0, xact_s: 0}

  def set(reading), do: :persistent_term.put(@key, Map.merge(@calm, reading))

  @doc "The next reads raise, as a probe on a database that cannot answer does."
  def fail, do: :persistent_term.put(@key, :fail)

  def reset, do: :persistent_term.erase(@key)

  def read(_repo) do
    case :persistent_term.get(@key, @calm) do
      :fail -> raise DBConnection.ConnectionError, "connection not available"
      reading -> reading
    end
  end
end
