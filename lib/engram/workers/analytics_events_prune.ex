defmodule Engram.Workers.AnalyticsEventsPrune do
  @moduledoc """
  Hourly retention sweep for `analytics_events`: rows older than two years
  are deleted in bounded batches, so each run deletes about an hour's worth.
  Idempotent. `analytics_events` has no RLS, so it runs without a tenant.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Analytics.Event
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @retention_days 730
  @batch 5_000

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)
    n = prune(cutoff, 0)
    Logger.info("analytics_events_prune deleted=#{n}", Metadata.with_category(:info, :oban, []))
    {:ok, n}
  end

  defp prune(cutoff, acc) do
    batch = from(e in Event, where: e.inserted_at < ^cutoff, select: e.id, limit: @batch)
    {n, _} = Repo.delete_all(from(e in Event, where: e.id in subquery(batch)))
    if n >= @batch, do: prune(cutoff, acc + n), else: acc + n
  end
end
