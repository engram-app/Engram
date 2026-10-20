defmodule Engram.Workers.AnalyticsEventsPrune do
  @moduledoc """
  Hourly retention sweep for `analytics_events`: rows older than two years
  are deleted in bounded batches, so each run deletes about an hour's worth.
  Idempotent. `analytics_events` has no RLS, so it runs without a tenant.

  Also the daily snapshots (`Engram.Insights.Snapshot`), one row per user or
  vault per day, retained as long as their readers look back: user metrics
  two years (the longest operator report window, `Insights.window_days/1`),
  vault metrics 180 days (the reports read the last 30, the per-user page
  the default 180-day window). One day per statement, so a run deletes about
  a day's rows.
  """
  use Oban.Worker, queue: :maintenance, max_attempts: 3

  import Ecto.Query

  alias Engram.Analytics.Event
  alias Engram.Insights.{UserDailyMetric, VaultDailyMetric}
  alias Engram.Logger.Metadata
  alias Engram.Repo

  require Logger

  @retention_days 730
  @metrics_retention [{UserDailyMetric, 730}, {VaultDailyMetric, 180}]
  @batch 5_000

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  @impl Oban.Worker
  def perform(%Oban.Job{}) do
    cutoff = DateTime.add(DateTime.utc_now(), -@retention_days, :day)
    n = prune(cutoff, 0)
    metrics = Enum.sum(for {schema, days} <- @metrics_retention, do: prune_days(schema, days))

    Logger.info(
      "analytics_events_prune deleted=#{n} metrics_deleted=#{metrics}",
      Metadata.with_category(:info, :oban, [])
    )

    {:ok, n}
  end

  defp prune_days(schema, days) do
    cutoff = Date.add(Date.utc_today(), -days)

    from(m in schema, where: m.date < ^cutoff, distinct: true, select: m.date)
    |> Repo.all()
    |> Enum.reduce(0, fn date, acc ->
      {n, _} = Repo.delete_all(from(m in schema, where: m.date == ^date))
      acc + n
    end)
  end

  defp prune(cutoff, acc) do
    batch = from(e in Event, where: e.inserted_at < ^cutoff, select: e.id, limit: @batch)
    {n, _} = Repo.delete_all(from(e in Event, where: e.id in subquery(batch)))
    if n >= @batch, do: prune(cutoff, acc + n), else: acc + n
  end
end
