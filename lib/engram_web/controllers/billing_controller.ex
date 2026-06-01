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
        end,
      caps: %{
        obsidian_connections: cap_json(Billing.effective_limit(user, :obsidian_connections_cap)),
        mcp_connections: cap_json(Billing.effective_limit(user, :mcp_connections_cap)),
        api_write_enabled: bool_json(Billing.effective_limit(user, :api_write_enabled))
      }
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
        starter: %{
          monthly: Application.get_env(:engram, :paddle_starter_monthly_price_id),
          annual: Application.get_env(:engram, :paddle_starter_annual_price_id)
        },
        pro: %{
          monthly: Application.get_env(:engram, :paddle_pro_monthly_price_id),
          annual: Application.get_env(:engram, :paddle_pro_annual_price_id)
        }
      },
      customer_email: user.email,
      custom_data: %{user_id: user.id},
      vaults_cap: cap_json(Billing.effective_limit(user, :vaults_cap))
    })
  end

  # Normalizes an effective limit to a JSON-friendly value: a positive integer
  # cap, or `null` for "unlimited" (`:unlimited` / `nil` / `-1`). The frontend
  # treats `null` as no cap.
  defp cap_json(:unlimited), do: nil
  defp cap_json(nil), do: nil
  defp cap_json(-1), do: nil
  defp cap_json(limit) when is_integer(limit), do: limit
  # Unknown/malformed override (e.g. a non-integer value) → treat as no cap
  # rather than 500 the endpoint.
  defp cap_json(_), do: nil

  # Boolean LimitKey: :unlimited (limits disabled) opens the gate; explicit
  # true/false flows through; anything else collapses to false to fail-closed.
  defp bool_json(:unlimited), do: true
  defp bool_json(true), do: true
  defp bool_json(false), do: false
  defp bool_json(_), do: false

  @doc """
  Customer-portal redirect. Without an `action` param this returns the generic
  overview URL; with `action=cancel` / `action=update_payment` it returns the
  matching per-subscription deep link so the UI can offer distinct buttons.
  """
  def customer_portal(conn, params) do
    with_billing(conn, fn ->
      user = conn.assigns.current_user

      result =
        case params["action"] do
          nil -> Billing.create_portal_session(user)
          action -> Billing.portal_action_url(user, action)
        end

      respond_with_url(conn, result)
    end)
  end

  @doc "Live subscription detail (next bill, billing cycle, scheduled change)."
  def subscription_detail(conn, _params) do
    with_billing(conn, fn ->
      case Billing.subscription_detail(conn.assigns.current_user) do
        {:ok, detail} -> json(conn, detail)
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  @doc "Transaction history plus the card behind the latest card payment."
  def transactions(conn, _params) do
    with_billing(conn, fn ->
      case Billing.billing_history(conn.assigns.current_user) do
        {:ok, history} -> json(conn, history)
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  @doc "Mint the hosted invoice URL for one of the user's own transactions."
  def transaction_invoice(conn, %{"id" => transaction_id}) do
    with_billing(conn, fn ->
      case Billing.transaction_invoice_url(conn.assigns.current_user, transaction_id) do
        {:ok, url} -> json(conn, %{url: url})
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, :not_found} -> not_found(conn, "transaction not found")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  @doc "Mint a transaction id for the in-app Paddle.js payment-method overlay."
  def payment_update_transaction(conn, _params) do
    with_billing(conn, fn ->
      case Billing.update_payment_transaction(conn.assigns.current_user) do
        {:ok, transaction_id} -> json(conn, %{transaction_id: transaction_id})
        {:error, :no_subscription} -> not_found(conn, "no subscription")
        {:error, reason} -> paddle_error(conn, reason)
      end
    end)
  end

  # Self-host (billing_enabled=false) never reaches Paddle: the page is hidden
  # client-side, but gate here too so a direct request 404s instead of erroring.
  defp with_billing(conn, fun) do
    if Application.get_env(:engram, :billing_enabled, false) == true do
      fun.()
    else
      not_found(conn, "billing disabled")
    end
  end

  defp respond_with_url(conn, {:ok, url}), do: json(conn, %{url: url})
  defp respond_with_url(conn, {:error, :no_subscription}), do: not_found(conn, "no subscription")
  defp respond_with_url(conn, {:error, reason}), do: paddle_error(conn, reason)

  defp not_found(conn, message), do: conn |> put_status(404) |> json(%{error: message})

  defp paddle_error(conn, reason) do
    Logger.error("Paddle billing error", reason_label: inspect(reason))
    conn |> put_status(502) |> json(%{error: "payment provider error"})
  end
end
