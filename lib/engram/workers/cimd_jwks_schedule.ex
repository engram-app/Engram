defmodule Engram.Workers.CimdJwksSchedule do
  @moduledoc """
  The 5-minute cron entry for `Engram.Workers.CimdJwksRefresh`. Enqueues the
  sweep 1 to 30 s out so vendor fetches do not land on the exact cron minute.

  The spread lives in `scheduled_at`, not a sleep in the sweep, so neither
  Oban's execution time nor its queue time includes it. This job is one insert,
  so it shares `maintenance` without holding a slot.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Workers.CimdJwksRefresh

  @spread_s 30

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    case %{} |> CimdJwksRefresh.new(schedule_in: :rand.uniform(@spread_s)) |> Oban.insert() do
      {:ok, _job} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
