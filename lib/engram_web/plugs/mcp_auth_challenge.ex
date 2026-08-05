defmodule EngramWeb.Plugs.McpAuthChallenge do
  @moduledoc """
  Attaches the RFC 9728 §5.1 `WWW-Authenticate` challenge to an unauthenticated
  401 on the MCP endpoint.

  MCP (2025-06-18 onward) makes the MCP server an OAuth 2.1 resource server, and
  a resource server answering 401 MUST say where to authenticate:

      WWW-Authenticate: Bearer resource_metadata="https://host/.well-known/oauth-protected-resource/api/mcp"

  Without it a spec-following client has no discovery entry point. Ours shipped
  a bare `{"error":"unauthorized"}`, and only clients that additionally *guess*
  the well-known path convention (Claude, MCPJam) ever connected.

  ## Why a separate plug rather than a line in `Plugs.Auth`

  `Plugs.Auth` is shared by six pipelines — the vault-scoped REST scope, admin,
  invites. Emitting this there would advertise MCP resource metadata on every
  `/api/notes` 401 and point SPA and plugin clients at an OAuth flow that is not
  theirs. The challenge is a property of *this resource*, so it is installed on
  the MCP scope only.

  ## Why `register_before_send`

  This plug runs BEFORE `Plugs.Auth` in the pipeline (it has to — `Auth` halts).
  `register_before_send/2` callbacks still run on a halted conn, so the header
  is attached on the way out, keyed on the status actually sent. Every plug in
  the MCP scope's stack that can 401 is therefore covered, not just `Auth` —
  `OAuthScopeEnforce` and the token-resolution paths included.
  """

  @behaviour Plug

  alias EngramWeb.OAuthMetadata

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    Plug.Conn.register_before_send(conn, &put_challenge/1)
  end

  defp put_challenge(%Plug.Conn{status: 401} = conn) do
    # Only when nothing upstream already set one — a more specific challenge
    # (e.g. `error="invalid_token"` on an expired bearer) is strictly better
    # information for the client and must not be flattened into this generic one.
    case Plug.Conn.get_resp_header(conn, "www-authenticate") do
      [] ->
        url = OAuthMetadata.resource_metadata_url(conn)
        Plug.Conn.put_resp_header(conn, "www-authenticate", ~s(Bearer resource_metadata="#{url}"))

      _ ->
        conn
    end
  end

  defp put_challenge(conn), do: conn
end
