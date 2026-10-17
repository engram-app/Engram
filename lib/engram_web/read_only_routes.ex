defmodule EngramWeb.ReadOnlyRoutes do
  @moduledoc """
  The one answer to "can this request change anything?", read by every plug
  that refuses writes to a credential with only read access (#174, #332):
  `VaultPlug` (a read-level vault) and `OAuthScopeEnforce` (no writable
  vault anywhere). Two copies of this list drifted once already: the vault plug
  exempted `/api/search`, the scope plug `/api/search` and `/api/mcp`, and
  neither knew `plan-change/preview`.

  Safe methods never write. These POSTs only read:

    * `/api/mcp`: JSON-RPC over POST; `McpController` refuses each write
      tool per call, so the transport itself must stay open.
    * `/api/search`: a query, sent as a body.
    * `/api/billing/plan-change/preview`: prices a hypothetical plan swap,
      changes and mints nothing (see the router).

  These POSTs write, but no vault data (no note, folder, attachment or
  vault), so a read-only credential may make them, exactly as it may call
  the MCP `send_feedback` tool (`Engram.MCP.Tools.writes_vault?/1`):

    * `/api/feedback`: a message to the Engram team.
    * `/api/logs`: the client's own diagnostic log lines. Rate limited per
      credential like every vault-scoped route (`PreAuthRateLimit`, and
      `RequireApiRpsBudget` for API keys).
    * `/api/telemetry/spans`: the client's trace spans.
  """

  @safe_methods ~w(GET HEAD OPTIONS)
  @read_only_posts [
    ["api", "mcp"],
    ["api", "search"],
    ["api", "billing", "plan-change", "preview"],
    # Write no vault data (above).
    ["api", "feedback"],
    ["api", "logs"],
    ["api", "telemetry", "spans"]
  ]

  # Only the POST on these paths is exempt; any other method there writes.
  @spec writes?(Plug.Conn.t()) :: boolean()
  def writes?(%Plug.Conn{method: method, path_info: path}),
    do: method not in @safe_methods and not (method == "POST" and path in @read_only_posts)
end
