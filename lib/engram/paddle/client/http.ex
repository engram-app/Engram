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
    url = base_url() <> "/customers/" <> customer_id <> "/portal-sessions"

    case Req.post(url, headers: headers(), json: %{}, receive_timeout: 10_000) do
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

  defp base_url do
    case Application.get_env(:engram, :paddle_env, "sandbox") do
      "production" -> @production_base
      _ -> @sandbox_base
    end
  end

  defp headers do
    [
      {"authorization", "Bearer " <> Application.fetch_env!(:engram, :paddle_api_key)},
      {"content-type", "application/json"}
    ]
  end
end
