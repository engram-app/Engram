defmodule Engram.Workers.PaddleCancelSubscription do
  @moduledoc """
  Retries `Lifecycle.cancel_paddle_subscription/2`'s Paddle call when the
  inline best-effort attempt during hard-delete fails.

  Hard-delete cascades the local `subscriptions` row regardless of whether
  the inline Paddle cancel succeeded (account deletion cannot block on a
  third party being up). A transient Paddle failure there used to be
  terminal: the local row was already gone, so nothing ever tried again, and
  Paddle kept billing a deleted account until the nightly reconciliation cron
  happened to notice (`Engram.Billing.Reconciliation`, `:missing_local`).

  This job is the retry that closes that gap. It carries the
  `paddle_subscription_id` captured at enqueue time — it does not look the
  local subscription back up, because by the time it runs the row (and
  possibly the user) is already gone: `Lifecycle` only enqueues this job
  from inside the hard-delete transaction's success branch, never before the
  commit point, so a job existing at all is itself proof the account really
  was deleted.

  `cancel/2` is the single place the Paddle cancel call + idempotency key are
  built. `Lifecycle.cancel_paddle_subscription/2` calls it for the inline
  attempt too, so the key format can't drift between the two call sites — if
  it did, a retry after a Paddle-side timeout (request succeeded, response
  lost) would use a different key than the original attempt and stop
  deduping into one cancellation.
  """

  use Oban.Worker, queue: :maintenance, max_attempts: 3

  alias Engram.Logger.Metadata
  alias Engram.Telemetry

  require Logger

  # A single bounded Paddle API call — never expected to hang, but Oban's
  # default is :infinity, which lets a wedged HTTP client hold this queue's
  # slot forever (see Engram.ObanWorkerTimeoutTest, #1496).
  @impl Oban.Worker
  def timeout(_job), do: :timer.minutes(1)

  def enqueue(user_id, paddle_subscription_id) do
    %{user_id: user_id, paddle_subscription_id: paddle_subscription_id}
    |> new()
    |> Oban.insert()
  end

  @doc "Cancels a Paddle subscription immediately, keyed for hard-delete's idempotency."
  def cancel(user_id, paddle_subscription_id) do
    Engram.Paddle.Client.impl().cancel_subscription(
      paddle_subscription_id,
      :immediately,
      idempotency_key: "hard-delete-#{user_id}"
    )
  end

  @impl Oban.Worker
  def perform(%Oban.Job{
        args: %{"user_id" => user_id, "paddle_subscription_id" => paddle_subscription_id}
      }) do
    case cancel(user_id, paddle_subscription_id) do
      {:ok, _data} ->
        :ok

      {:error, reason} = error ->
        # NEVER inspect(reason): a Paddle error is {:paddle_error, status, body}
        # where body is echoed Paddle JSON that can carry customer PII. Mirrors
        # Engram.Billing.Reconciliation's fetch-failure logging.
        Logger.error(
          "paddle_cancel_retry_failed",
          Metadata.with_category(:error, :lifecycle,
            user_id: user_id,
            paddle_subscription_id: paddle_subscription_id,
            error_kind: Telemetry.error_kind(reason),
            status: paddle_error_status(reason)
          )
        )

        error
    end
  end

  defp paddle_error_status({:paddle_error, status, _body}), do: status
  defp paddle_error_status(_), do: nil
end
