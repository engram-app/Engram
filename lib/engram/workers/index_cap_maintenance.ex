defmodule Engram.Workers.IndexCapMaintenance do
  @moduledoc """
  COMPAT SHIM, remove in a later contract PR (along with its entry in the
  Oban queue config test).

  This worker ran the index-cap sweeps (evict notes past the cap on a
  downgrade, re-open a freed slot on a delete). The search-coverage cap was
  removed on 2026-10-17, so nothing enqueues it any more. It stays as a no-op
  for one release so jobs enqueued by the previous release, or by an old node
  during a rolling deploy, complete instead of failing as an unknown worker.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  @impl Oban.Worker
  def perform(%Oban.Job{}), do: :ok
end
