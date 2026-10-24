defmodule Engram.Billing.Workers.PaddleReconcile do
  @moduledoc """
  Oban cron worker for Paddle reconciliation. Daily: calls
  `Engram.Billing.Reconciliation.run/1` with a 7-day window. Every 5
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
    # :args too: the daily drift run and the stalled scan are the same worker,
    # and [:worker] alone would drop one as a duplicate whenever they land
    # within the 60 s period (a manual run, a retry, a future schedule move).
    unique: [period: 60, fields: [:worker, :args]]

  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(15)

  # Stalled-checkout scan (args `%{"scan" => "stalled_checkouts"}`, every 5
  # min): see `Reconciliation.report_stalled_checkouts/1`. Anchored on the
  # job's cron tick so a retry re-reads the same window.
  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"scan" => "stalled_checkouts"}, inserted_at: inserted_at}) do
    case Engram.Billing.Reconciliation.report_stalled_checkouts(
           scan_anchor(inserted_at || DateTime.utc_now())
         ) do
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

  @doc """
  The scan's anchor: the cron tick the job was inserted for, rounded to the
  nearest minute. Ticks are exactly one window apart (5 minutes), so windows
  anchored on them tile, and the window end (anchor - 15m) is never later than 15 minutes
  before the run: nothing younger than the grace is reported. Rounding (not
  flooring) absorbs a DB clock that inserts the job a hair before its minute.
  """
  @spec scan_anchor(DateTime.t()) :: DateTime.t()
  def scan_anchor(%DateTime{} = inserted_at) do
    DateTime.from_unix!(div(DateTime.to_unix(inserted_at) + 30, 60) * 60)
  end
end
