defmodule Engram.Billing.Workers.PaddleReconcile do
  @moduledoc """
  Oban cron worker for Paddle reconciliation. Daily: calls
  `Engram.Billing.Reconciliation.run/1` with a 7-day window. Every 15
  minutes (args `%{"scan" => "stalled_checkouts"}`): reports checkouts stuck
  at `action_required` via `Reconciliation.report_stalled_checkouts/1`. Drift is logged at `:error` and captured by Sentry —
  the worker itself always returns `:ok` so Oban doesn't mark the job
  failed for data drift (which is signal, not job failure).

  `max_attempts: 2` so a transient Repo / Paddle blip on the first run
  doesn't have to wait 24h for the next cron tick. `Reconciliation.run/1`
  catches expected `{:error, _}` from the Paddle client internally; the
  retry is for unexpected raises (DBConnection.ConnectionError, etc).

  Emits `[:engram, :paddle, :reconcile, :run]` per execution with the
  result's `:skipped` field tagged as `outcome` (`:ok` when nil). Lets a
  future Prometheus alert fire on truncation/fetch-fail rate without
  parsing logs.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 2,
    # :args too: the daily drift run and the 15-minute stalled scan share the
    # 02:00 tick, and [:worker] alone would drop one as a duplicate.
    unique: [period: 60, fields: [:worker, :args]]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  # Stalled-checkout scan (args `%{"scan" => "stalled_checkouts"}`, every 15
  # min): see `Reconciliation.report_stalled_checkouts/1`. Anchored on the
  # job's insert tick, floored to the 15-minute boundary, so a retry re-reads
  # the same window instead of sliding past it.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scan" => "stalled_checkouts"}, inserted_at: inserted_at}) do
    tick = inserted_at || DateTime.utc_now()
    anchor = DateTime.from_unix!(div(DateTime.to_unix(tick), 900) * 900)

    case Engram.Billing.Reconciliation.report_stalled_checkouts(anchor) do
      {:error, _reason} = error -> error
      _count -> :ok
    end
  end

  def perform(_job) do
    result = Engram.Billing.Reconciliation.run(7)
    outcome = result.skipped || :ok

    :telemetry.execute(
      [:engram, :paddle, :reconcile, :run],
      %{paddle_total: result.paddle_total, drift_count: length(result.drift)},
      %{outcome: outcome}
    )

    :ok
  end
end
