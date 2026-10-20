defmodule EngramWeb.AnalyticsController do
  use EngramWeb, :controller

  alias Engram.Analytics
  alias Engram.Analytics.ClientEvents
  alias Engram.Analytics.SyncSummary

  @max_events 20
  # Events per user per minute. The SPA sends a handful per page; a burst
  # past this is a loop or a forged client, and costs one 429.
  @per_minute 120

  # POST /api/analytics/sync-summary. The plugin calls it at most twice per
  # first sync, and treats a 404 (an older server) as a no-op.
  def sync_summary(conn, params) do
    case SyncSummary.track(conn.assigns.current_user, params) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
    end
  end

  # POST /api/analytics/events. The web app's own funnel events, recorded in
  # our event log only (`Analytics.record_client_event/3`): the browser sends
  # them to PostHog itself. Each event is checked against the SPA's schema
  # (`ClientEvents`); one that fails is dropped, the rest are kept.
  def events(conn, %{"events" => events})
      when is_list(events) and length(events) <= @max_events do
    user = conn.assigns.current_user

    case EngramWeb.RateLimiter.hit(
           "client_events:#{user.id}",
           60_000,
           @per_minute,
           :analytics_activity,
           max(length(events), 1)
         ) do
      {:allow, _} ->
        for raw <- events, {:ok, event, props} <- [ClientEvents.validate(raw)] do
          Analytics.record_client_event(user, event, props)
        end

        send_resp(conn, 204, "")

      {:deny, _} ->
        conn |> put_status(429) |> json(%{error: "rate_limited"})
    end
  end

  def events(conn, _params), do: conn |> put_status(422) |> json(%{error: "invalid_events"})
end
