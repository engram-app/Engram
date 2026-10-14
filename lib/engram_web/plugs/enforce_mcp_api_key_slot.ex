defmodule EngramWeb.Plugs.EnforceMcpApiKeySlot do
  @moduledoc """
  Holds a personal API key used on `/api/mcp` to the same connection limit as
  an OAuth MCP grant (#1974).

  MCP over an API key is open on every tier: `RequireApiRpsBudget` and
  `RequireApiWriteEnabled` exempt `/api/mcp`, because those two keys price the
  REST API, not MCP. What MCP is limited by is `mcp_connections_cap` (and the
  AI usage meter, which `Engram.Search.search/4` charges on every transport).
  The key counts as one connection: refused 402 when the user's active OAuth
  MCP grants already fill the cap.

  ponytail: one direction only. A consent that would add an OAuth grant while
  a key is in MCP use is not refused, because nothing records that a key was
  used on MCP. Add an `mcp_last_used_at` on api_keys if that gap matters.
  """

  alias Engram.Billing
  alias Engram.Connections

  def init(opts), do: opts

  def call(%Plug.Conn{assigns: %{current_api_key: _, current_user: user}} = conn, _opts) do
    case Billing.cap(user, :mcp_connections_cap) do
      nil ->
        conn

      limit ->
        current = Connections.count_active(user.id, :mcp) + 1

        if current <= limit,
          do: conn,
          else:
            EngramWeb.LimitResponse.halt(
              conn,
              "mcp_connections_exceeded",
              :mcp_connections_cap,
              limit,
              current
            )
    end
  end

  def call(conn, _opts), do: conn
end
