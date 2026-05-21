defmodule Engram.Email.Resend do
  @moduledoc """
  Resend.com transactional email provider. Requires `RESEND_API_KEY` env var.

  POST https://api.resend.com/emails
    Authorization: Bearer <key>
    {"from": "...", "to": ["..."], "subject": "...", "html": "..."}
  """

  @behaviour Engram.Email.Provider

  require Logger

  @endpoint "https://api.resend.com/emails"

  @impl true
  def send(to, subject, html, opts \\ []) do
    case Application.get_env(:engram, :resend_api_key) do
      nil ->
        {:error, :missing_api_key}

      "" ->
        {:error, :missing_api_key}

      key ->
        from =
          Keyword.get(opts, :from) ||
            Application.get_env(:engram, :email_from, "Engram <hello@engram.page>")

        body = %{from: from, to: [to], subject: subject, html: html}

        result =
          Req.post(@endpoint,
            json: body,
            headers: [{"authorization", "Bearer #{key}"}],
            receive_timeout: 10_000,
            retry: :transient,
            max_retries: 2
          )

        case result do
          {:ok, %{status: status}} when status in 200..299 ->
            :ok

          {:ok, %{status: status, body: body}} ->
            Logger.error("Resend send failed",
              status: status,
              body_size: byte_size(inspect(body))
            )

            {:error, {:http_error, status}}

          {:error, reason} ->
            Logger.error("Resend transport error", reason: inspect(reason))
            {:error, reason}
        end
    end
  end
end
