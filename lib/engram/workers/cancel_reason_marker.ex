defmodule Engram.Workers.CancelReasonMarker do
  @moduledoc """
  Oban worker: file `portal_no_reason` for a scheduled cancel that came with
  no reason (`Engram.Feedback.record_missing_cancel_reason/4`).

  Enqueued by `EngramWeb.Webhooks.PostHogForwarder` when `subscription.updated`
  first shows a cancel `scheduled_change`, so a portal cancel is counted when
  it happens, not at period end (up to a year later for an annual plan). It
  runs `@delay_s` later because the in-app dialog files its reason only after
  the cancel call returns, and our event log buffers writes; checking on the
  webhook itself would race the dialog's own reason.

  `subscription.canceled` runs the same check, so a cancel that skips
  scheduling (immediate) is still filed there, and this marker stops it from
  being filed twice. The unique window only collapses Paddle's repeated
  `subscription.updated` while the cancel is pending; a duplicate that slips
  through finds the first marker and files nothing.
  """

  use Oban.Worker,
    queue: :events,
    max_attempts: 3,
    unique: [keys: [:user_id, :effective_at], period: 24 * 3600]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Feedback

  @delay_s 600

  @doc "The job for a cancel scheduled now, `@delay_s` out."
  @spec new_for(Ecto.UUID.t(), DateTime.t(), String.t() | nil) :: Oban.Job.changeset()
  def new_for(user_id, started_at, effective_at) do
    new(
      %{
        "user_id" => user_id,
        "started_at" => DateTime.to_iso8601(started_at),
        "scheduled_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "effective_at" => effective_at
      },
      schedule_in: @delay_s
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"user_id" => user_id} = args}) do
    with %User{} = user <- Accounts.get_user(user_id),
         {:ok, started_at, _} <- DateTime.from_iso8601(args["started_at"]),
         {:ok, scheduled_at, _} <- DateTime.from_iso8601(args["scheduled_at"]) do
      Feedback.record_missing_cancel_reason(user, started_at, "portal_no_reason", scheduled_at)
    else
      _ -> :ok
    end
  end
end
