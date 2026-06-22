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
  @stop_event [:phoenix, :endpoint, :stop]
  # Fires when a matched controller/action raises (e.g. a TenantError or
  # DBConnection.ConnectionError from a query inside the action). The :stop
  # event does NOT carry these — its before_send never runs on a raise — so the
  # structured request line would otherwise be missing for the very requests
  # that 500.
  @exception_event [:phoenix, :router_dispatch, :exception]

  @doc """
  Attach (or re-attach) the telemetry handlers. Idempotent — detaches first
  so repeated boots don't accumulate stale handlers.
  """
  def attach do
    _ = :telemetry.detach(@handler_id)

    :ok =
      :telemetry.attach_many(
        @handler_id,
        [@stop_event, @exception_event],
        &__MODULE__.handle_event/4,
        nil
      )
  end

  @doc false
  def handle_event(@stop_event, %{duration: duration}, %{conn: conn}, _config) do
    if suppress_request_log?(conn) do
      :ok
    else
      emit_request_log(conn, duration)
    end
  end

  def handle_event(@exception_event, _measurements, %{conn: conn} = metadata, _config) do
    Logger.error(
      "request exception",
      method: conn.method,
      status: conn.status,
      route: route(conn),
      user_id: current_user_id(conn),
      kind: metadata[:kind],
      # Bounded: the reason can be a Postgrex/DBConnection error wrapping bound
      # params or creds — only the struct/atom class escapes.
      error_kind: Engram.Telemetry.error_kind(metadata[:reason]),
      request_path: conn.request_path
    )
  end

  def handle_event(_, _, _, _), do: :ok

  defp emit_request_log(conn, duration) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)

    Logger.log(
      level_for_status(conn.status),
      "#{conn.method} #{conn.status} in #{duration_ms}ms",
      method: conn.method,
      status: conn.status,
      route: route(conn),
      request_path: conn.request_path,
      request_query: conn.query_string,
      user_id: current_user_id(conn),
      mtls_clientcert_subject: mtls_clientcert_subject(conn)
    )
  end

  # ALB liveness (/health) and readiness (/health/deep) probes hit every task
  # every 1-2s. Logging each successful one is pure noise — and at sustained
  # volume it is the bulk of the log shipper's traffic, which can tip the Loki
  # pipeline into a retry-amplification storm. Drop only the *successful*
  # probes (status < 400); a degraded health check still logs at :error/:warning
  # so a failing target stays visible. Keyed on the matched controller, never
  # the path, so it can't be spoofed by an arbitrary /health-prefixed request.
  defp suppress_request_log?(%Plug.Conn{status: status, private: private})
       when is_integer(status) and status < 400,
       do: private[:phoenix_controller] == EngramWeb.HealthController

  defp suppress_request_log?(_), do: false

  # A 5xx flood must elevate above :info so level-keyed alerting sees it; a 4xx
  # is a client error worth a :warning; everything else stays :info.
  defp level_for_status(status) when status >= 500, do: :error
  defp level_for_status(status) when status >= 400, do: :warning
  defp level_for_status(_), do: :info

  defp current_user_id(%Plug.Conn{assigns: %{current_user: %{id: id}}}), do: id
  defp current_user_id(_), do: nil

  # The matched controller/action, as "Module#action" — the endpoint shape an
  # operator needs to triage. Phoenix sets these in conn.private after routing.
  # Unlike request_path (which the redact filter scrubs because wildcard routes
  # like `/notes/*path` embed note titles), the controller+action pair is fixed
  # by the route table and never contains user data — safe to log in the clear.
  # nil for unmatched requests (static assets, 404s, plug-only endpoints).
  defp route(%Plug.Conn{private: private}) do
    case {private[:phoenix_controller], private[:phoenix_action]} do
      {nil, _} -> nil
      {_, nil} -> nil
      {controller, action} -> "#{inspect(controller)}##{action}"
    end
  end

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
