defmodule Engram.Billing.Workers.PaddleReconcile do
  @moduledoc """
  Daily Oban cron worker. Calls `Engram.Billing.Reconciliation.run/1` with
  a 7-day window. Drift is logged at `:error` and captured by Sentry —
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
    unique: [period: 60, fields: [:worker]]

  @impl Oban.Worker
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
