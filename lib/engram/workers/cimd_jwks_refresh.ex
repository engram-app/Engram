defmodule Engram.Workers.CimdJwksRefresh do
  @moduledoc """
  Every 5 minutes, refetch every CIMD client's JWKS (#1974) so the token path
  finds a fresh persisted key set instead of fetching.

  A cron entry of its own (the crontab is `{expr, worker}` pairs, one worker
  per slot); the work is `Engram.Workers.CimdRefresh`'s `kind: "jwks"` sweep.
  The start is jittered up to 30 s so vendor fetches do not land on the exact
  cron minute; a job's `jitter_ms` arg overrides it (tests pass 0).
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 1

  alias Engram.Workers.CimdRefresh

  @jitter_ms 30_000

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(4)

  @impl Oban.Worker
  def perform(%Oban.Job{args: args} = job) do
    args = Map.merge(%{"kind" => "jwks", "jitter_ms" => @jitter_ms}, args)
    CimdRefresh.perform(%{job | args: args})
  end
end
