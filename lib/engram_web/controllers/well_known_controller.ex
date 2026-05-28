defmodule EngramWeb.WellKnownController do
  @moduledoc """
  Serves OAuth 2.1 discovery documents per RFC 8414 (authorization server
  metadata) and RFC 9728 (protected resource metadata).

  The base URL is derived from the host the client actually dialed, *when*
  that host is in the configured origin allowlist (`:cors_origin`, populated
  from `PHX_HOST`). This lets a single backend that fronts multiple canonical
  domains (e.g. `app.engram.page` and `staging.engram.page`) advertise the
  matching issuer instead of a hardcoded one — otherwise a client connecting
  to one domain gets metadata pointing at the other and aborts on the RFC 9728
  resource self-check. Hosts outside the allowlist fall back to the canonical
  `EngramWeb.Endpoint.url/0`; we never reflect an unvetted Host header into the
  issuer, which would let a spoofed Host poison discovery.
  """
  use EngramWeb, :controller

  def protected_resource(conn, _params) do
    base = base_url(conn)

    json(conn, %{
      resource: base <> "/api/mcp",
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_documentation: base <> "/docs"
    })
  end

  def authorization_server(conn, _params) do
    base = base_url(conn)

    json(conn, %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      revocation_endpoint: base <> "/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none"],
      scopes_supported: ["mcp"]
    })
  end

  defp base_url(conn) do
    canonical = EngramWeb.Endpoint.url()
    candidate = "#{URI.parse(canonical).scheme}://#{conn.host}"

    if candidate in Application.get_env(:engram, :cors_origin, []) do
      candidate
    else
      canonical
    end
  end
end
