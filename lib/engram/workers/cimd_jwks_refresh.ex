defmodule Engram.Workers.CimdJwksRefresh do
  @moduledoc """
  Refetch every CIMD client's JWKS (#1974) so the token path finds a fresh
  persisted key set instead of fetching. The work is
  `Engram.Workers.CimdRefresh`'s `kind: "jwks"` sweep.

  Not a cron entry itself: `Engram.Workers.CimdJwksSchedule` enqueues it every
  5 minutes with a random `scheduled_at` spread. The spread used to be a sleep
  inside this job, which Oban counted as execution time, so the dashboard
  showed a ~15 s "exec" that was all sleep.
  """
  # Its own 1-slot queue, not `maintenance`: a 5-minute sweep of vendor
  # fetches would otherwise sit in one of that lane's 2 slots most of every
  # hour (ObanQueueConfigTest).
  use Oban.Worker, queue: :cimd_refresh, max_attempts: 1

  alias Engram.Workers.CimdRefresh

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(4)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    CimdRefresh.perform(%{job | args: Map.put(args, "kind", "jwks")})
  end
end
