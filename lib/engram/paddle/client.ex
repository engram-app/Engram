defmodule Engram.Paddle.Client do
  @moduledoc """
  Behaviour for the Paddle Billing API client.

  Implementations: `Engram.Paddle.Client.HTTP` (Req-based, default) and
  `Engram.Paddle.ClientMock` (Mox, test env).

  Dispatch through `Engram.Paddle.Client.impl/0` so callers don't bind to a
  concrete module — the test runtime swaps the impl via app config.
  """

  @doc """
  Create a customer-portal session and return its overview URL.

  Paddle endpoint: `POST /customers/{customer_id}/portal-sessions`. The
  returned URL routes the customer to Paddle's hosted portal where they
  can update payment methods and cancel subscriptions.
  """
  @callback create_customer_portal_session(customer_id :: String.t()) ::
              {:ok, url :: String.t()} | {:error, term()}

  @doc """
  Fetch the raw Paddle subscription object.

  Paddle endpoint: `GET /subscriptions/{id}`. Returns the decoded `data` map
  verbatim (`next_billed_at`, `billing_cycle`, `scheduled_change`,
  `recurring_transaction_details`, `currency_code`, …) — normalization is the
  caller's job so this stays a thin transport.
  """
  @callback get_subscription(subscription_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  List the transactions for a subscription, most recent first.

  Paddle endpoint: `GET /transactions?subscription_id={id}`. Returns the
  decoded `data` list verbatim. Pagination beyond the first page is not
  followed — the billing-history view shows the most recent page.
  """
  @callback list_transactions(subscription_id :: String.t()) ::
              {:ok, [map()]} | {:error, term()}

  @doc """
  Fetch the hosted invoice/receipt URL for a completed transaction.

  Paddle endpoint: `GET /transactions/{id}/invoice`. The URL is short-lived,
  so it is minted on demand rather than persisted.
  """
  @callback get_transaction_invoice(transaction_id :: String.t()) ::
              {:ok, url :: String.t()} | {:error, term()}

  @doc """
  Create a customer-portal session and return its full `urls` map.

  Paddle endpoint: `POST /customers/{customer_id}/portal-sessions`. Unlike
  `create_customer_portal_session/1` (which returns only the overview URL),
  this returns the whole `data.urls` structure including the per-subscription
  `cancel_subscription` and `update_subscription_payment_method` deep links.
  """
  @callback get_portal_session(customer_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  Fetch a transaction for updating the subscription's payment method in-app.

  Paddle endpoint: `GET /subscriptions/{id}/update-payment-method-transaction`.
  Returns the decoded `data` map; the `id` feeds `Paddle.Checkout.open({
  transactionId })` so the card is updated in an overlay without leaving the app.
  """
  @callback get_update_payment_transaction(subscription_id :: String.t()) ::
              {:ok, map()} | {:error, term()}

  @doc """
  List subscriptions updated since the given DateTime, paginated.

  Paddle endpoint: `GET /subscriptions?updated_at[GTE]={iso}&per_page=200`.
  Follows `meta.pagination.next` until exhausted.

  Returns:
    * `{:ok, list}` — full pagination consumed
    * `{:partial, list, :max_pages_exceeded}` — hard page-count cap hit;
      list is whatever was collected. Callers MUST treat this as drift
      signal, not a clean read.
    * `{:partial, list, :pagination_loop}` — Paddle returned a `next` URL
      we'd already fetched; broke the loop. Same caller contract.
    * `{:error, reason}` — transport / non-2xx.

  Feeds the daily reconciliation Oban worker
  (`Engram.Billing.Workers.PaddleReconcile`).
  """
  @callback list_subscriptions(since :: DateTime.t()) ::
              {:ok, [map()]}
              | {:partial, [map()], :max_pages_exceeded | :pagination_loop}
              | {:error, term()}

  @doc """
  Cancel a Paddle subscription.

  Paddle endpoint: `POST /subscriptions/{id}/cancel` with body
  `{"effective_from": "next_billing_period"|"immediately"}`. Optional
  `:idempotency_key` opt is forwarded as the `Paddle-IK` header so retries
  (Lifecycle.hard_delete, manual ops re-runs) don't double-cancel.

  Used by:
    * `Engram.Accounts.Lifecycle.hard_delete/2` — `effective_from: :immediately`
    * `Engram.Subscriptions.cancel/2` — user-initiated cancel-at-period-end

  Returns `{:ok, data}` (decoded Paddle subscription) on 200; `{:error, _}` on
  transport/non-2xx. Caller decides whether the failure is fatal — hard-delete
  swallows it as best-effort, user-initiated cancel surfaces 503.
  """
  @callback cancel_subscription(
              subscription_id :: String.t(),
              effective_from :: :immediately | :next_billing_period,
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Preview a subscription plan change without committing it.

  Paddle endpoint: `PATCH /subscriptions/{id}/preview` with body
  `{"items": [...], "proration_billing_mode": "..."}`. Returns the decoded
  `data` map; surfaces `old_total`, `new_total`, `immediate_charge_or_credit`,
  `next_billed_at` for the inline PlanChangePanel to render. Read-only on
  Paddle's side — safe to call freely.
  """
  @callback preview_subscription_update(
              subscription_id :: String.t(),
              items :: [map()],
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @doc """
  Apply a subscription update (plan change).

  Paddle endpoint: `PATCH /subscriptions/{id}` with body
  `{"items": [...], "proration_billing_mode": "..."}` (and optionally
  `"scheduled_change": null` to reverse a scheduled cancel). Optional
  `:idempotency_key` opt is forwarded as the `Paddle-IK` header. Webhook
  mirror syncs the resulting state into our DB; callers don't write here.
  """
  @callback update_subscription(
              subscription_id :: String.t(),
              items :: [map()],
              opts :: keyword()
            ) :: {:ok, map()} | {:error, term()}

  @default_impl Engram.Paddle.Client.HTTP

  @doc "Returns the configured client implementation module."
  def impl, do: Application.get_env(:engram, :paddle_client, @default_impl)
end
