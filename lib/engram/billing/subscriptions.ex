defmodule Engram.Billing.Subscriptions do
  @moduledoc """
  User-initiated subscription operations on top of `Engram.Paddle.Client`.

  Distinct from `Engram.Billing` (which exposes read-side helpers like
  `get_subscription/1`, `tier/1`, `active?/1`) and from
  `Engram.Accounts.Lifecycle` (which cancels Paddle as a side-effect of
  account deletion using `effective_from: :immediately`). This module is
  for explicit user actions on their own subscription — the `/api/billing`
  cancel/update endpoints route here.

  Each call to Paddle carries a deterministic `idempotency_key` so retries
  (network blips, user re-clicks) cannot double-cancel.
  """

  alias Engram.Accounts.User
  alias Engram.Billing
  alias Engram.Billing.Subscription
  alias Engram.Paddle.Client

  @doc """
  Cancel the user's Paddle subscription.

  Defaults to `:next_billing_period` so the user keeps service through the
  end of the current paid period — the user-facing cancel flow. Pass
  `:immediately` only when the caller has its own reason to terminate now
  (rare in user-initiated paths; account hard-delete has its own helper).

  Returns:
    * `{:ok, paddle_data}` — Paddle accepted the cancel; payload is the
      decoded Paddle subscription. Webhook-driven sync (`PaddleWebhook`)
      mirrors the resulting state into our DB; callers don't need to write
      anything here.
    * `{:error, :no_active_subscription}` — no `paddle_subscription_id` on
      file. Self-host users + users who have never paid land here.
    * `{:error, :paddle_unavailable}` — Paddle returned non-2xx or the
      transport failed. Surface as 503 at the controller boundary.
  """
  @spec cancel(User.t(), :immediately | :next_billing_period) ::
          {:ok, map()} | {:error, :no_active_subscription | :paddle_unavailable}
  def cancel(user, effective_from \\ :next_billing_period)
      when effective_from in [:immediately, :next_billing_period] do
    case Billing.get_subscription(user) do
      %Subscription{paddle_subscription_id: sub_id} when is_binary(sub_id) ->
        do_cancel(user, sub_id, effective_from)

      _ ->
        {:error, :no_active_subscription}
    end
  end

  defp do_cancel(user, sub_id, effective_from) do
    idempotency_key = "cancel-#{user.id}-#{sub_id}-#{System.unique_integer([:positive])}"

    case Client.impl().cancel_subscription(sub_id, effective_from,
           idempotency_key: idempotency_key
         ) do
      {:ok, data} -> {:ok, data}
      {:error, _reason} -> {:error, :paddle_unavailable}
    end
  end
end
