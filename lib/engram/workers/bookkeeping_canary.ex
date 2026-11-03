defmodule Engram.Workers.BookkeepingCanary do
  @moduledoc """
  Hourly cron: `Engram.Bookkeeping.Canary.run/0`, the random-sample tripwire
  for the database-kept bookkeeping. Read-only; disabling it loses detection,
  never data.
  """
  # `states: :incomplete`, as DataMigrationsRunner: two runs never overlap, but
  # a completed run does not swallow the next hourly one.
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 3000, states: :incomplete]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(_job) do
    _ = Engram.Bookkeeping.Canary.run()
    :ok
  end
end
