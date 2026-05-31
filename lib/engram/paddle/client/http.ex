defmodule Engram.Paddle.Client.HTTP do
  @moduledoc """
  Default `Engram.Paddle.Client` implementation — thin Req wrapper over the
  Paddle Billing REST API. Base URL is chosen by `:paddle_env`
  (`"sandbox"` → sandbox-api.paddle.com, anything else → api.paddle.com).
  """

  @behaviour Engram.Paddle.Client

  require Logger

  @sandbox_base "https://sandbox-api.paddle.com"
  @production_base "https://api.paddle.com"

  @impl true
  def create_customer_portal_session(customer_id) when is_binary(customer_id) do
    with {:ok, api_key} <- fetch_api_key() do
      url = base_url() <> "/customers/" <> customer_id <> "/portal-sessions"

      case Req.post(url, headers: headers(api_key), json: %{}, receive_timeout: 10_000) do
        {:ok,
         %Req.Response{
           status: 201,
           body: %{"data" => %{"urls" => %{"general" => %{"overview" => overview}}}}
         }} ->
          {:ok, overview}

        {:ok, %Req.Response{status: status, body: body}} ->
          Logger.warning("Paddle portal-session non-201",
            status: status,
            reason_label: inspect(body)
          )

          {:error, {:paddle_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_subscription(subscription_id) when is_binary(subscription_id) do
    with {:ok, api_key} <- fetch_api_key() do
      url = base_url() <> "/subscriptions/" <> subscription_id

      case Req.get(url, headers: headers(api_key), receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
          {:ok, data}

        {:ok, %Req.Response{status: status, body: body}} ->
          log_non_2xx("subscription", status, body)
          {:error, {:paddle_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def list_transactions(subscription_id) when is_binary(subscription_id) do
    with {:ok, api_key} <- fetch_api_key() do
      url = base_url() <> "/transactions"

      params = [subscription_id: subscription_id, order_by: "billed_at[DESC]", per_page: 50]

      case Req.get(url, headers: headers(api_key), params: params, receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} when is_list(data) ->
          {:ok, data}

        {:ok, %Req.Response{status: status, body: body}} ->
          log_non_2xx("transactions", status, body)
          {:error, {:paddle_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_transaction_invoice(transaction_id) when is_binary(transaction_id) do
    with {:ok, api_key} <- fetch_api_key() do
      url = base_url() <> "/transactions/" <> transaction_id <> "/invoice"

      case Req.get(url, headers: headers(api_key), receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 200, body: %{"data" => %{"url" => invoice_url}}}} ->
          {:ok, invoice_url}

        {:ok, %Req.Response{status: status, body: body}} ->
          log_non_2xx("transaction-invoice", status, body)
          {:error, {:paddle_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def get_portal_session(customer_id) when is_binary(customer_id) do
    with {:ok, api_key} <- fetch_api_key() do
      url = base_url() <> "/customers/" <> customer_id <> "/portal-sessions"

      case Req.post(url, headers: headers(api_key), json: %{}, receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 201, body: %{"data" => %{"urls" => urls}}}} ->
          {:ok, urls}

        {:ok, %Req.Response{status: status, body: body}} ->
          log_non_2xx("portal-session", status, body)
          {:error, {:paddle_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def list_subscriptions(%DateTime{} = since) do
    with {:ok, api_key} <- fetch_api_key() do
      iso = DateTime.to_iso8601(since)
      url = base_url() <> "/subscriptions"
      params = [{"updated_at[GTE]", iso}, {"per_page", 200}]
      list_pages(url, params, headers(api_key), [])
    end
  end

  defp list_pages(url, params, headers, acc) do
    case Req.get(url, params: params, headers: headers, receive_timeout: 15_000) do
      {:ok, %Req.Response{status: 200, body: %{"data" => data} = body}} when is_list(data) ->
        case get_in(body, ["meta", "pagination", "next"]) do
          nil ->
            {:ok, Enum.reverse([data | acc]) |> List.flatten()}

          "" ->
            {:ok, Enum.reverse([data | acc]) |> List.flatten()}

          next_url when is_binary(next_url) ->
            # Paddle's `next` is a fully-qualified URL with all query params
            # encoded — don't pass `params:` again or Req appends them.
            list_pages(next_url, [], headers, [data | acc])
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        log_non_2xx("subscriptions-list", status, body)
        {:error, {:paddle_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_update_payment_transaction(subscription_id) when is_binary(subscription_id) do
    with {:ok, api_key} <- fetch_api_key() do
      url =
        base_url() <>
          "/subscriptions/" <> subscription_id <> "/update-payment-method-transaction"

      case Req.get(url, headers: headers(api_key), receive_timeout: 10_000) do
        {:ok, %Req.Response{status: 200, body: %{"data" => data}}} ->
          {:ok, data}

        {:ok, %Req.Response{status: status, body: body}} ->
          log_non_2xx("update-payment-transaction", status, body)
          {:error, {:paddle_error, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  defp log_non_2xx(label, status, body) do
    Logger.warning("Paddle #{label} non-2xx", status: status, reason_label: inspect(body))
  end

  defp fetch_api_key do
    case Application.get_env(:engram, :paddle_api_key) do
      nil -> {:error, :paddle_not_configured}
      "" -> {:error, :paddle_not_configured}
      key when is_binary(key) -> {:ok, key}
    end
  end

  defp base_url do
    case Application.get_env(:engram, :paddle_env, "sandbox") do
      "production" -> @production_base
      _ -> @sandbox_base
    end
  end

  defp headers(api_key) do
    [
      {"authorization", "Bearer " <> api_key},
      {"content-type", "application/json"}
    ]
  end
end
