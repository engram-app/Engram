defmodule EngramWeb.WebhookController do
  use EngramWeb, :controller

  alias Engram.Auth.Clerk.Webhook, as: ClerkWebhook
  alias Engram.Billing
  alias Engram.Email.Suppression
  alias Engram.Webhooks.Svix

  require Logger

  @max_signature_age_seconds 300

  def clerk(conn, _params) do
    with {:ok, sig_header} <- get_header(conn, "svix-signature"),
         {:ok, id} <- get_header(conn, "svix-id"),
         {:ok, ts} <- get_header(conn, "svix-timestamp"),
         {:ok, payload} <- read_body_once(conn),
         :ok <- Svix.verify(id, ts, payload, sig_header, clerk_webhook_secret()) do
      event = Jason.decode!(payload)
      _ = ClerkWebhook.handle(event)
      json(conn, %{status: "ok"})
    else
      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

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

  def resend(conn, _params) do
    with {:ok, sig_header} <- get_header(conn, "svix-signature"),
         {:ok, id} <- get_header(conn, "svix-id"),
         {:ok, ts} <- get_header(conn, "svix-timestamp"),
         {:ok, payload} <- read_body_once(conn),
         :ok <- Svix.verify(id, ts, payload, sig_header, resend_webhook_secret()) do
      payload |> Jason.decode!() |> handle_resend_event()
      json(conn, %{status: "ok"})
    else
      {:error, reason} ->
        conn |> put_status(400) |> json(%{error: to_string(reason)})
    end
  end

  # Resend posts a bounce/complaint per delivery problem. Add the affected
  # recipients to the suppression list so we stop sending to them. Transient
  # bounces (full mailbox, temporary receiving-server issue) are NOT suppressed
  # — only permanent failures and complaints. Other event types (delivered,
  # opened, etc.) are acknowledged and ignored.
  defp handle_resend_event(%{"type" => "email.complained", "data" => data}) do
    suppress_recipients(data, :complained)
  end

  defp handle_resend_event(%{"type" => "email.bounced", "data" => data}) do
    if transient_bounce?(data), do: :ok, else: suppress_recipients(data, :bounced)
  end

  defp handle_resend_event(_), do: :ok

  defp transient_bounce?(%{"bounce" => %{"type" => type}}), do: type == "Transient"
  defp transient_bounce?(_), do: false

  defp suppress_recipients(data, reason) do
    data
    |> Map.get("to", [])
    |> List.wrap()
    |> Enum.each(fn email ->
      case Suppression.suppress(email, reason) do
        {:ok, _} ->
          :ok

        {:error, changeset} ->
          # Log (no raw address — PII) so a swallowed insert is diagnosable.
          # We still ack 200 so Resend doesn't retry a payload we can't persist.
          Logger.error("Resend suppression insert failed",
            category: :email,
            reason_label: reason,
            errors: Ecto.Changeset.traverse_errors(changeset, fn {m, _} -> m end) |> inspect()
          )
      end
    end)
  end

  defp resend_webhook_secret, do: Application.get_env(:engram, :resend_webhook_secret)

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

  # ── Clerk webhook helpers ────────────────────────────────────

  defp get_header(conn, name) do
    case Plug.Conn.get_req_header(conn, name) do
      [val | _] -> {:ok, val}
      _ -> {:error, "missing #{name} header"}
    end
  end

  defp clerk_webhook_secret, do: Application.get_env(:engram, :clerk_webhook_secret)
end
