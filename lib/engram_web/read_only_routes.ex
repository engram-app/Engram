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
  """

  @safe_methods ~w(GET HEAD OPTIONS)
  @read_only_posts [
    ["api", "mcp"],
    ["api", "search"],
    ["api", "billing", "plan-change", "preview"]
  ]

  @spec writes?(Plug.Conn.t()) :: boolean()
  def writes?(%Plug.Conn{method: method, path_info: path}),
    do: method not in @safe_methods and path not in @read_only_posts
end
