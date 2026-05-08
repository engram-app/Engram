defmodule EngramWeb.BillingController do
  use EngramWeb, :controller

  require Logger

  alias Engram.Billing

  def status(conn, _params) do
    user = conn.assigns.current_user
    sub = Billing.get_subscription(user)

    json(conn, %{
      tier: to_string(Billing.tier(user)),
      active: Billing.active?(user),
      trial_days_remaining: Billing.trial_days_remaining(user),
      subscription:
        if sub do
          %{
            status: sub.status,
            tier: sub.tier,
            current_period_end: sub.current_period_end
          }
        end
    })
  end

  def create_checkout(conn, %{"tier" => tier}) when tier in ~w(starter pro) do
    user = conn.assigns.current_user

    case Billing.create_checkout_session(user, tier) do
      {:ok, url} ->
        json(conn, %{url: url})

      {:error, error} ->
        Logger.error("Stripe checkout error", stripe_error_meta(error))
        conn |> put_status(502) |> json(%{error: "payment provider error"})
    end
  end

  def create_checkout(conn, _params) do
    conn |> put_status(400) |> json(%{error: "tier must be 'starter' or 'pro'"})
  end

  def customer_portal(conn, _params) do
    user = conn.assigns.current_user

    case Billing.create_portal_session(user) do
      {:ok, url} ->
        json(conn, %{url: url})

      {:error, :no_subscription} ->
        conn |> put_status(404) |> json(%{error: "no subscription"})

      {:error, error} ->
        Logger.error("Stripe portal error", stripe_error_meta(error))
        conn |> put_status(502) |> json(%{error: "payment provider error"})
    end
  end

  # Extract safe fields from a Stripe.Error — skip `:extra` which can contain
  # the raw response body (and with it, echoed user input). Falls back to a
  # bounded `inspect/1` for any other shape stripity_stripe might return.
  defp stripe_error_meta(%Stripe.Error{} = e) do
    [code: e.code, message: e.message, request_id: e.request_id]
  end

  # Logger metadata helper only — both call sites pipe into Logger.error/2.
  defp stripe_error_meta(other), do: [reason: inspect(other)] # noqa: T3.0.6 — Logger metadata only
end
