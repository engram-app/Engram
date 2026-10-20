defmodule EngramWeb.AnalyticsController do
  use EngramWeb, :controller

  alias Engram.Analytics.SyncSummary

  # POST /api/analytics/sync-summary. The plugin calls it at most twice per
  # first sync, and treats a 404 (an older server) as a no-op.
  def sync_summary(conn, params) do
    case SyncSummary.track(conn.assigns.current_user, params) do
      :ok -> send_resp(conn, 204, "")
      {:error, reason} -> conn |> put_status(422) |> json(%{error: Atom.to_string(reason)})
    end
  end
end
