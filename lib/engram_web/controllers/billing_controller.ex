defmodule EngramWeb.BillingController do
  use EngramWeb, :controller

  alias Engram.Billing

  require Logger

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

  @doc """
  Returns the public configuration the frontend needs to open the Paddle.js
  overlay. The client merges its own affiliate / utm params into
  `custom_data` before calling `Paddle.Checkout.open()`.
  """
  def config(conn, _params) do
    user = conn.assigns.current_user

    json(conn, %{
      client_token: Application.get_env(:engram, :paddle_client_token),
      environment: Application.get_env(:engram, :paddle_env, "sandbox"),
      price_ids: %{
        starter: Application.get_env(:engram, :paddle_starter_price_id),
        pro: Application.get_env(:engram, :paddle_pro_price_id)
      },
      customer_email: user.email,
      custom_data: %{user_id: user.id}
    })
  end

  def customer_portal(conn, _params) do
    user = conn.assigns.current_user

    case Billing.create_portal_session(user) do
      {:ok, url} ->
        json(conn, %{url: url})

      {:error, :no_subscription} ->
        conn |> put_status(404) |> json(%{error: "no subscription"})

      {:error, reason} ->
        Logger.error("Paddle portal error", reason_label: inspect(reason))
        conn |> put_status(502) |> json(%{error: "payment provider error"})
    end
  end
end
