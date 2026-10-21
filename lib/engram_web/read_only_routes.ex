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
    * `/api/telemetry/spans`: the client's trace spans.

  Every `/api/attachment-uploads` route writes, `GET` included (the chunked
  upload's session status belongs to its writer).

  `POST /api/logs` is NOT here: it stores lines against the addressed vault,
  a vault-scoped write a read-only credential is refused. The MCP
  transport's GET and DELETE answer 405 on an auth-free route, so no
  exemption is needed for them.
  """

  @safe_methods ~w(GET HEAD OPTIONS)
  @read_only_posts [
    ["api", "mcp"],
    ["api", "search"],
    ["api", "billing", "plan-change", "preview"],
    # Write no vault data (above).
    ["api", "feedback"],
    ["api", "telemetry", "spans"]
  ]

  # Only the POST on these paths is exempt; any other method there writes.
  # Every chunked-upload route writes, its GET included: a session exists only
  # because a writer opened one, so a read-only credential has no business
  # probing it.
  @spec writes?(Plug.Conn.t()) :: boolean()
  def writes?(%Plug.Conn{path_info: ["api", "attachment-uploads" | _]}), do: true

  def writes?(%Plug.Conn{method: method, path_info: path}),
    do: method not in @safe_methods and not (method == "POST" and path in @read_only_posts)
end
