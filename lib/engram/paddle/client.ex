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
  Follows `meta.pagination.next` until exhausted. Returns the flattened
  list of decoded subscription `data` maps. Feeds the daily reconciliation
  Oban worker (`Engram.Billing.Workers.PaddleReconcile`).
  """
  @callback list_subscriptions(since :: DateTime.t()) ::
              {:ok, [map()]} | {:error, term()}

  @default_impl Engram.Paddle.Client.HTTP

  @doc "Returns the configured client implementation module."
  def impl, do: Application.get_env(:engram, :paddle_client, @default_impl)
end
