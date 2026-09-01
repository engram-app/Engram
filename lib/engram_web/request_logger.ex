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

  alias Engram.Logger.Metadata
  alias EngramWeb.RequestMeta

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
      Metadata.with_category(:error, :http,
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
    )
  end

  def handle_event(_, _, _, _), do: :ok

  defp emit_request_log(conn, duration) do
    duration_ms = System.convert_time_unit(duration, :native, :millisecond)
    level = level_for_conn(conn)

    meta =
      [
        method: conn.method,
        status: conn.status,
        route: route(conn),
        request_path: conn.request_path,
        request_query: conn.query_string,
        user_id: current_user_id(conn),
        mtls_clientcert_subject: mtls_clientcert_subject(conn)
      ]
      |> maybe_put_reject_reason(conn)
      |> maybe_put_client_identity(conn)

    Logger.log(
      level,
      "#{conn.method} #{conn.status} in #{duration_ms}ms",
      level
      |> Metadata.with_category(:http, meta)
      |> maybe_force_loki_ship(conn)
    )
  end

  # Quieting the LEVEL must not silently DELETE the record.
  # `Category.loki_ship?(:info, :http)` is false, so a response downgraded to
  # :info by `expected_client_status` would stop reaching Loki entirely — an
  # operator debugging "device linking is stuck for user X" would find nothing
  # at all, which is a worse failure than the warn noise this replaces.
  # Same per-entry override `Engram.Logs.insert_logs/2` uses for diagnostic
  # client entries. Volume is not a concern: these lines are a handful per
  # login, unlike the successful-2xx firehose that keeps :http off the
  # info-ships list in the first place.
  # Metadata.ship_to_loki/1, never a bare Keyword.put: Fluent Bit routes on the
  # STRING field, so setting the boolean alone shipped nothing (engram-infra#1095).
  defp maybe_force_loki_ship(meta, %Plug.Conn{assigns: %{expected_client_status: true}}),
    do: Metadata.ship_to_loki(meta)

  defp maybe_force_loki_ship(meta, _conn), do: meta

  # A rejecting plug (e.g. VaultPlug) assigns :reject_reason so the reason rides
  # this single request line instead of a second per-request log. Omitted entirely
  # for normal requests so the field only appears on rejections.
  defp maybe_put_reject_reason(meta, conn) do
    case conn.assigns[:reject_reason] do
      nil -> meta
      reason -> Keyword.put(meta, :reason, reason)
    end
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

  # A controller may mark a 4xx as a NORMAL step in its protocol rather than a
  # client error. The only current user is the device flow's
  # `authorization_pending` poll: the code is alive and the human simply has
  # not approved yet, so at a 5s poll over a 300s TTL one SUCCESSFUL login
  # emitted ~60 warnings (prod 2026-08-13 — ~82% of the warn stream). A log
  # level is the claim "a human should look at this"; spending it on a happy
  # path is how a working system reads as an incident.
  #
  # NB: this does NOT feed grafana's loki-auth-failure-burst alert, despite
  # looking like it should — that rule filters metadata_category="auth" and
  # these request lines are category :http. The volume argument stands alone.
  #
  # Opt-in PER RESPONSE, set server-side — never blanket-4xx and never keyed on
  # route+status, so a genuine client error on the same endpoint (malformed
  # body, missing param) still surfaces at :warning. 5xx is never downgradable.
  defp level_for_conn(%Plug.Conn{status: status, assigns: %{expected_client_status: true}})
       when is_integer(status) and status < 500,
       do: :info

  defp level_for_conn(%Plug.Conn{status: status}), do: level_for_status(status)

  # A 5xx flood must elevate above :info so level-keyed alerting sees it; a 4xx
  # is a client error worth a :warning; everything else stays :info.
  defp level_for_status(status) when status >= 500, do: :error
  defp level_for_status(status) when status >= 400, do: :warning
  defp level_for_status(_), do: :info

  # Client attribution for the device-flow endpoints ONLY. They are public and
  # pre-auth (`user_id` is null until the code is approved), so a polling
  # client is otherwise entirely unattributable — you cannot tell which client
  # is calling, and a stuck poller reads identically to a healthy one.
  # Scoped rather than global because a UA on every request line is bytes on
  # every log in the system for a need specific to these routes.
  #
  # NO client IP here, deliberately. `config/prod.exs` states the standing
  # policy that request headers and client IPs stay OUT of Loki — that is why
  # prod excludes Sentry.PlugContext's `:__sentry__` blob rather than logging
  # it. IPs are still recorded where they have a purpose and a lifecycle (ToS
  # agreements, DCR registrations) as DB columns, not sprayed across every log
  # line in a hosted, long-retention aggregator. The user agent carries no
  # credential and is already persisted deliberately elsewhere
  # (`onboarding/agreement.ex`, `oauth_register_controller`), so it stays.
  #
  # If per-source correlation is ever needed here (device-code guessing), the
  # answer is a keyed digest via Engram.Crypto.HMAC, not the raw address.
  # TRUNCATED, because this is an unauthenticated trust boundary. The header is
  # attacker-controlled, RedactFilter neither scrubs nor bounds `:user_agent`,
  # and prod serializes all metadata — so with Bandit's 10_000-byte header cap
  # a client hammering /api/auth/device/token could push ~10KB of arbitrary text
  # per request into a hosted, long-retention aggregator. That is the same
  # ingest-cost failure mode this PR exists to fix. 200 chars holds every real
  # UA (the Obsidian one is ~120) and nothing else.
  @user_agent_log_limit 200

  defp maybe_put_client_identity(meta, %Plug.Conn{private: private} = conn) do
    if private[:phoenix_controller] == EngramWeb.DeviceAuthController do
      Keyword.put(meta, :user_agent, truncate_user_agent(RequestMeta.get_user_agent(conn)))
    else
      meta
    end
  end

  defp truncate_user_agent(nil), do: nil
  defp truncate_user_agent(ua), do: String.slice(ua, 0, @user_agent_log_limit)

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
