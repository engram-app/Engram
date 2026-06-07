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
    * `{:error, {:paddle_error, status}}` — Paddle returned a non-2xx
      response. Status preserved so the controller can map 4xx (user-
      caused, e.g. swapping to the current price) to 422 and 5xx (Paddle
      outage) to 502 distinctly.
    * `{:error, :paddle_unavailable}` — transport failure (Req error,
      timeout, DNS, etc. — no HTTP response). Surface as 503.
  """
  @spec cancel(User.t(), :immediately | :next_billing_period) ::
          {:ok, map()}
          | {:error, :no_active_subscription | :paddle_unavailable | {:paddle_error, integer()}}
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
    Client.impl().cancel_subscription(sub_id, effective_from,
      idempotency_key: idempotency_key(:cancel, user, sub_id, effective_from)
    )
    |> normalize_paddle_result()
  end

  # Paddle HTTP layer returns `{:error, {:paddle_error, status}}` for non-2xx
  # responses and `{:error, transport_reason}` for connection failures.
  # Preserve the status for the controller; collapse transport errors to a
  # single `:paddle_unavailable` since callers can't act on transport detail.
  defp normalize_paddle_result({:ok, data}), do: {:ok, data}

  defp normalize_paddle_result({:error, {:paddle_error, status}}),
    do: {:error, {:paddle_error, status}}

  defp normalize_paddle_result({:error, _transport_reason}),
    do: {:error, :paddle_unavailable}

  # Idempotency keys MUST be deterministic per logical request — Paddle's
  # `Paddle-IK` header is the dedup signal for retries (network blip, React
  # Query auto-retry, user double-click). A counter or timestamp produces a
  # fresh key every call, defeating dedup; Paddle then accepts both calls as
  # distinct requests and we double-cancel / double-charge.
  #
  # phash2 of (verb, user_id, sub_id, target_state) is stable across BEAM
  # restarts and process boundaries while still varying per distinct logical
  # action — switching cadence later mints a different key (target_state
  # changes), so legitimate re-tries collapse but legitimate re-cancels don't.
  defp idempotency_key(verb, user, sub_id, target_state) do
    hash = :erlang.phash2({verb, user.id, sub_id, target_state})
    "#{verb}-#{user.id}-#{sub_id}-#{hash}"
  end

  @doc """
  Preview a plan change without committing.

  Paddle proration mode is `prorated_immediately` — the inline panel renders
  `old_total`, `new_total`, `immediate_charge_or_credit`, `next_billed_at`
  for the user to confirm. Read-only on Paddle's side.

  Returns `{:ok, preview}` or `{:error, :no_active_subscription | :paddle_unavailable}`.
  """
  @spec preview_plan_change(User.t(), String.t()) ::
          {:ok, map()}
          | {:error, :no_active_subscription | :paddle_unavailable | {:paddle_error, integer()}}
  def preview_plan_change(user, new_price_id) when is_binary(new_price_id) do
    with_active_sub(user, fn sub_id ->
      Client.impl().preview_subscription_update(
        sub_id,
        [%{price_id: new_price_id, quantity: 1}],
        proration_billing_mode: "prorated_immediately"
      )
    end)
  end

  @doc """
  Commit a plan change.

  Idempotency key prevents double-apply on retry. Webhook mirror reflects
  the new plan into our DB; callers don't write here.

  Returns `{:ok, paddle_data}` or `{:error, :no_active_subscription | :paddle_unavailable}`.
  """
  @spec confirm_plan_change(User.t(), String.t()) ::
          {:ok, map()}
          | {:error, :no_active_subscription | :paddle_unavailable | {:paddle_error, integer()}}
  def confirm_plan_change(user, new_price_id) when is_binary(new_price_id) do
    with_active_sub(user, fn sub_id ->
      Client.impl().update_subscription(
        sub_id,
        [%{price_id: new_price_id, quantity: 1}],
        idempotency_key: idempotency_key(:plan_change, user, sub_id, new_price_id),
        proration_billing_mode: "prorated_immediately"
      )
    end)
  end

  @doc """
  Reverse a scheduled cancel by clearing Paddle's `scheduled_change`.

  Patches the subscription with `scheduled_change: nil` and no item changes.
  Returns `{:ok, paddle_data}` or `{:error, :no_active_subscription | :paddle_unavailable}`.
  """
  @spec reverse_cancel(User.t()) ::
          {:ok, map()}
          | {:error, :no_active_subscription | :paddle_unavailable | {:paddle_error, integer()}}
  def reverse_cancel(user) do
    with_active_sub(user, fn sub_id ->
      Client.impl().update_subscription(
        sub_id,
        [],
        idempotency_key: idempotency_key(:reverse_cancel, user, sub_id, :clear),
        scheduled_change: nil
      )
    end)
  end

  defp with_active_sub(user, fun) do
    case Billing.get_subscription(user) do
      %Subscription{paddle_subscription_id: sub_id} when is_binary(sub_id) ->
        sub_id |> fun.() |> normalize_paddle_result()

      _ ->
        {:error, :no_active_subscription}
    end
  end
end
