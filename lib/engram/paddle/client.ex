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

  @default_impl Engram.Paddle.Client.HTTP

  @doc "Returns the configured client implementation module."
  def impl, do: Application.get_env(:engram, :paddle_client, @default_impl)
end
