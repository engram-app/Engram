defmodule EngramWeb.WebhookController do
  use EngramWeb, :controller

  alias Engram.Billing

  require Logger

  @max_signature_age_seconds 300

  def paddle(conn, _params) do
    with {:ok, sig_header} <- get_signature(conn),
         {:ok, payload} <- read_body_once(conn),
         :ok <- verify_signature(payload, sig_header) do
      event = Jason.decode!(payload)

      case Billing.upsert_from_paddle_event(event) do
        {:ok, _} ->
          json(conn, %{status: "ok"})

        {:error, reason} ->
          Logger.warning("Paddle webhook processing failed",
            event_type: event["event_type"],
            event_id: event["event_id"],
            reason: format_reason(reason)
          )

          json(conn, %{status: "ok"})
      end
    else
      {:error, reason} ->
        conn
        |> put_status(400)
        |> json(%{error: to_string(reason)})
    end
  end

  defp get_signature(conn) do
    case Plug.Conn.get_req_header(conn, "paddle-signature") do
      [sig] -> {:ok, sig}
      _ -> {:error, "missing paddle-signature header"}
    end
  end

  defp read_body_once(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, "no raw body available"}
      body -> {:ok, body}
    end
  end

  # Paddle signs notifications as HMAC-SHA256("<ts>:<body>") with the
  # notification secret. The header is `ts=<unix>;h1=<hex>`, semicolon-
  # delimited. Reject anything older than @max_signature_age_seconds to
  # prevent replay.
  defp verify_signature(payload, sig_header) do
    with {:ok, secret} <- fetch_notification_secret(),
         {:ok, timestamp} <- extract_timestamp(sig_header),
         {:ok, expected_sig} <- extract_h1_signature(sig_header),
         :ok <- check_timestamp_age(timestamp) do
      signed_payload = "#{timestamp}:#{payload}"

      computed =
        :crypto.mac(:hmac, :sha256, secret, signed_payload)
        |> Base.encode16(case: :lower)

      if Plug.Crypto.secure_compare(computed, expected_sig) do
        :ok
      else
        {:error, "invalid signature"}
      end
    end
  end

  # Fail clearly when PADDLE_NOTIFICATION_SECRET is missing rather than letting
  # :crypto.mac/4 crash on a nil key. The 400 the caller emits is appropriate:
  # we cannot verify, so we cannot accept.
  defp fetch_notification_secret do
    case Application.get_env(:engram, :paddle_notification_secret) do
      nil -> {:error, "webhook secret not configured"}
      "" -> {:error, "webhook secret not configured"}
      secret when is_binary(secret) -> {:ok, secret}
    end
  end

  defp check_timestamp_age(timestamp_str) do
    age = abs(System.system_time(:second) - String.to_integer(timestamp_str))

    if age <= @max_signature_age_seconds do
      :ok
    else
      {:error, "timestamp too old"}
    end
  end

  defp extract_timestamp(header) do
    case Regex.run(~r/ts=(\d+)/, header) do
      [_, ts] -> {:ok, ts}
      _ -> {:error, "invalid signature format"}
    end
  end

  defp extract_h1_signature(header) do
    case Regex.run(~r/h1=([a-f0-9]+)/, header) do
      [_, sig] -> {:ok, sig}
      _ -> {:error, "invalid signature format"}
    end
  end

  # Ecto changesets stringify with their changed values — for webhook events
  # those values come from Paddle (potentially echoing emails or customer
  # input). Reduce to the error tuple list, which carries only field names
  # and validator messages.
  defp format_reason(%Ecto.Changeset{} = cs) do
    # noqa: T3.0.6 — Logger metadata only
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end) |> inspect()
  end

  defp format_reason(reason) when is_atom(reason), do: reason
  # noqa: T3.0.6 — Logger metadata only
  defp format_reason(reason), do: inspect(reason)
end
