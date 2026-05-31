defmodule Engram.Billing.Workers.PaddleReconcile do
  @moduledoc """
  Daily Oban cron worker. Calls `Engram.Billing.Reconciliation.run/1` with
  a 7-day window. Drift is logged at `:error` and captured by Sentry —
  the worker itself always returns `:ok` so Oban doesn't mark the job
  failed for data drift (which is signal, not job failure).
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 1,
    unique: [period: 60, fields: [:worker]]

  @impl Oban.Worker
  def perform(_job) do
    _ = Engram.Billing.Reconciliation.run(7)
    :ok
  end
end
