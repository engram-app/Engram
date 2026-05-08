defmodule EngramWeb.WebhookController do
  use EngramWeb, :controller

  require Logger

  alias Engram.Billing

  @max_signature_age_seconds 300

  def stripe(conn, _params) do
    with {:ok, sig_header} <- get_signature(conn),
         {:ok, payload} <- read_body_once(conn),
         :ok <- verify_signature(payload, sig_header) do
      event = Jason.decode!(payload)

      case Billing.upsert_from_stripe_event(event) do
        {:ok, _} ->
          json(conn, %{status: "ok"})

        {:error, reason} ->
          Logger.warning("Stripe webhook processing failed",
            event_type: event["type"],
            event_id: event["id"],
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
    case Plug.Conn.get_req_header(conn, "stripe-signature") do
      [sig] -> {:ok, sig}
      _ -> {:error, "missing stripe-signature header"}
    end
  end

  defp read_body_once(conn) do
    case conn.assigns[:raw_body] do
      nil -> {:error, "no raw body available"}
      body -> {:ok, body}
    end
  end

  defp verify_signature(payload, sig_header) do
    secret = Application.get_env(:engram, :stripe_webhook_secret)

    with {:ok, timestamp} <- extract_timestamp(sig_header),
         {:ok, expected_sig} <- extract_v1_signature(sig_header),
         :ok <- check_timestamp_age(timestamp) do
      signed_payload = "#{timestamp}.#{payload}"

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

  defp check_timestamp_age(timestamp_str) do
    age = abs(System.system_time(:second) - String.to_integer(timestamp_str))

    if age <= @max_signature_age_seconds do
      :ok
    else
      {:error, "timestamp too old"}
    end
  end

  defp extract_timestamp(header) do
    case Regex.run(~r/t=(\d+)/, header) do
      [_, ts] -> {:ok, ts}
      _ -> {:error, "invalid signature format"}
    end
  end

  defp extract_v1_signature(header) do
    case Regex.run(~r/v1=([a-f0-9]+)/, header) do
      [_, sig] -> {:ok, sig}
      _ -> {:error, "invalid signature format"}
    end
  end

  # Ecto changesets stringify with their changed values — for webhook events
  # those values come from Stripe (potentially echoing emails or customer
  # input). Reduce to the error tuple list, which carries only field names
  # and validator messages.
  # Logger metadata helper only — sole call site is Logger.warning/2 above.
  defp format_reason(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, _opts} -> msg end) |> inspect() # noqa: T3.0.6 — Logger metadata only
  end

  defp format_reason(reason) when is_atom(reason), do: reason
  defp format_reason(reason), do: inspect(reason) # noqa: T3.0.6 — Logger metadata only
end
