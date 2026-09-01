defmodule EngramWeb.Plugs.EnforceSearchCap do
  @moduledoc """
  Free-tier abuse defense on `POST /api/search` — the REST half of the
  rolling-24h search caps. `Engram.Usage.SearchCap` owns the rule (which
  bucket, what capacity, whether it's spent); this plug only maps a denial
  onto a 402 via `EngramWeb.LimitResponse` so the UpgradeDialog surface
  routes the reason like any other plan limit.

  Fires only for `POST /api/search` — note reads, manifest pulls and
  attachment fetches are not counted, so this plug can sit on a broad
  pipeline cheaply.

  **This plug is not the whole gate.** MCP searches never reach it: they
  arrive as a JSON-RPC `tools/call` at `POST /api/mcp` and call
  `Engram.Search.search/4` directly, so `EngramWeb.McpController` spends the
  same bucket through `SearchCap` at its own dispatch point. Adding a new
  search entry point means calling `SearchCap.spend/2` there too — a
  path-shaped gate here can only ever cover this one route.
  """

  alias Engram.Usage.SearchCap
  alias EngramWeb.LimitResponse

  def init(opts), do: opts

  def call(%Plug.Conn{method: "POST", request_path: "/api/search"} = conn, _opts) do
    case SearchCap.spend(conn.assigns, conn.assigns.current_user) do
      :ok -> conn
      {:denied, key, limit} -> LimitResponse.halt(conn, reason_for(key), key, limit, limit)
    end
  end

  def call(conn, _opts), do: conn

  defp reason_for(:external_ai_searches_per_day), do: "external_ai_searches_per_day_exceeded"
  defp reason_for(:inapp_searches_per_day), do: "inapp_searches_per_day_exceeded"
end
