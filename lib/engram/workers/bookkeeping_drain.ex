defmodule Engram.Workers.BookkeepingDrain do
  @moduledoc """
  Cron backstop: `Engram.Bookkeeping.Drain.run/0`, every 15 minutes. Each tick
  reads a few partial-index pages (empty in steady state) and hands the users
  with drift to the workers that repair it. Crons are backstops; the queue is
  the throttle (`docs/context/oban-scheduling-model.md`).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 600, states: :incomplete]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(5)

  @impl Oban.Worker
  def perform(_job) do
    _ = Engram.Bookkeeping.Drain.run()
    :ok
  end
end
