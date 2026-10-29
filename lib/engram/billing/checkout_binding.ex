defmodule Engram.Billing.CheckoutBinding do
  @moduledoc """
  Server-side binding between a Paddle checkout and the Engram user who
  opened it.

  `GET /api/billing/config` hands the frontend `custom_data/1`, which the
  overlay passes to `Paddle.Checkout.open(customData: ...)`. Paddle copies it
  onto the subscription, so the first webhook for that subscription carries
  it back. `verify/1` accepts the `user_id` only when `sig` is a token this
  server signed for that same id.

  Checked on the insert path: every `subscription.created` (including
  retries and replays), and any other subscription event whose
  `paddle_subscription_id` no row holds yet. Other events for a stored
  subscription match by `paddle_subscription_id` and need no token.

  Recovery for a subscription left unbound: a replay resends the original
  payload, so it cannot add a token. Mint fresh data with `custom_data/1`
  in a release shell and PATCH it onto the Paddle subscription
  (see `docs/context/paddle-integration.md`).
  """

  @salt "paddle_checkout"
  # A token is minted when the billing page loads config and is used at
  # checkout. The first webhook arrives within Paddle's retry window (about
  # two days); 30 days leaves room for a dashboard replay.
  @max_age 30 * 24 * 60 * 60

  @doc "The `custom_data` map the checkout overlay sends for `user_id`."
  @spec custom_data(Ecto.UUID.t()) :: %{user_id: Ecto.UUID.t(), sig: String.t()}
  def custom_data(user_id) do
    %{user_id: user_id, sig: Phoenix.Token.sign(EngramWeb.Endpoint, @salt, user_id)}
  end

  @doc """
  The verified user id from a webhook's `custom_data`. `:missing` when no
  `user_id` is present, `:unverified` when the signature is absent, invalid,
  expired, or minted for a different user.
  """
  @spec verify(term()) :: {:ok, Ecto.UUID.t()} | :missing | :unverified
  def verify(%{"user_id" => id} = custom_data) when is_binary(id) do
    with {:ok, uuid} <- Ecto.UUID.cast(id),
         sig when is_binary(sig) <- custom_data["sig"],
         {:ok, ^uuid} <- Phoenix.Token.verify(EngramWeb.Endpoint, @salt, sig, max_age: @max_age) do
      {:ok, uuid}
    else
      :error -> :missing
      _ -> :unverified
    end
  end

  def verify(_), do: :missing
end
