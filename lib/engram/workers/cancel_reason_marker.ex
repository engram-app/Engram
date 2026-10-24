defmodule Engram.Workers.CancelReasonMarker do
  @moduledoc """
  Oban worker: file `portal_no_reason` for a scheduled cancel that came with
  no reason (`Engram.Feedback.record_missing_cancel_reason/4`).

  Enqueued by `EngramWeb.Webhooks.PostHogForwarder` on every
  `subscription.updated` that carries a cancel `scheduled_change`, so a portal cancel is counted when
  it happens, not at period end (up to a year later for an annual plan). It
  runs `@delay_s` later because the in-app dialog files its reason only after
  the cancel call returns, and our event log buffers writes; checking on the
  webhook itself would race the dialog's own reason.

  `subscription.canceled` runs the same check, so a cancel that skips
  scheduling (immediate) is still filed there, and finds this marker rather
  than filing a second one.

  Paddle re-sends `subscription.updated` while the cancel is pending. Unique
  over pending jobs only, replacing args and run time: the LAST DELIVERED
  schedule wins, so an undo then re-cancel gets its own check instead of being
  dropped as a duplicate. (An out-of-order Paddle retry can put an older
  schedule back; that needs a cancel, undo and re-cancel inside ten minutes.)
  Once a job has run, a later resend enqueues a new one that finds the marker
  (or the reason) and files nothing.
  """

  use Oban.Worker,
    queue: :events,
    max_attempts: 3,
    unique: [keys: [:user_id, :effective_at], states: [:available, :scheduled], period: :infinity],
    # A due-but-not-yet-run job keeps its run time: moving it would run it now.
    replace: [scheduled: [:args, :scheduled_at], available: [:args]]

  alias Engram.Accounts
  alias Engram.Accounts.User
  alias Engram.Feedback

  @delay_s 600

  @doc """
  The check for a cancel Paddle scheduled at `scheduled_at` (the event's
  `occurred_at`, so a retried delivery never looks newer than a later undo),
  run `@delay_s` from now.
  """
  @spec new_for(Ecto.UUID.t(), DateTime.t(), String.t() | nil, DateTime.t()) ::
          Ecto.Changeset.t()
  def new_for(user_id, started_at, effective_at, scheduled_at) do
    new(
      %{
        "user_id" => user_id,
        "started_at" => DateTime.to_iso8601(started_at),
        "scheduled_at" => DateTime.to_iso8601(scheduled_at),
        "effective_at" => effective_at
      },
      schedule_in: @delay_s
    )
  end

  @impl Oban.Worker
  def timeout(_job), do: :timer.seconds(30)

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
