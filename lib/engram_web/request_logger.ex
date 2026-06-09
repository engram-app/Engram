defmodule EngramWeb.RequestLogger do
  @moduledoc """
  Telemetry handler that emits one structured log line per HTTP request.

  Replaces Phoenix's default `Plug.Telemetry` log emission, which interpolates
  `conn.method` and `conn.request_path` directly into the message body — past
  the reach of `Engram.Logger.RedactFilter`, which by design only scrubs
  metadata, not message strings.

  Phoenix's emission is suppressed via `plug Plug.Telemetry, log: false` in
  `EngramWeb.Endpoint`. This module attaches at boot from `Engram.Application`.

  Message body holds only safe scalars (`method`, `status`, `duration_ms`).
  Sensitive fields (`request_path`, `request_query`) are routed through
  metadata where the redact filter scrubs them. `user_id` is forwarded for
  triage; it is not in the redact filter's sensitive-key set.
  """

  require Logger

  @handler_id :engram_request_logger
  @event [:phoenix, :endpoint, :stop]

  @doc """
  Attach (or re-attach) the telemetry handler. Idempotent — detaches first
  so repeated boots don't accumulate stale handlers.
  """
  def attach do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach(
        @handler_id,
        @event,
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @doc false
  def handle_event(@event, %{duration: duration}, %{conn: conn}, _config) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.info(
      "#{conn.method} #{conn.status} in #{duration_ms}ms",
      method: conn.method,
      status: conn.status,
      request_path: conn.request_path,
      request_query: conn.query_string,
      user_id: current_user_id(conn),
      mtls_clientcert_subject: mtls_clientcert_subject(conn)
    )
  end

  def handle_event(_, _, _, _), do: :ok

  defp current_user_id(%Plug.Conn{assigns: %{current_user: %{id: id}}}), do: id
  defp current_user_id(_), do: nil

  # x-amzn-mtls-clientcert-subject is injected by ALB when its HTTPS
  # listener has mutual_authentication set to "passthrough" or "verify"
  # and a client cert was presented (or any cert, in passthrough mode).
  # Present = CF→ALB mTLS handshake reached us carrying a cert. Absent
  # = no AOP layer in front (dev, test, AOP disabled — in verify mode
  # a missing cert never reaches HTTP at all since the TLS handshake
  # fails first).
  #
  # Plug normalizes header names to lowercase, so the match key is
  # lowercase regardless of what ALB sends on the wire.
  defp mtls_clientcert_subject(%Plug.Conn{} = conn) do
    conn
    |> Plug.Conn.get_req_header("x-amzn-mtls-clientcert-subject")
    |> List.first()
  end
end
