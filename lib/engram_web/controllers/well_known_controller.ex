defmodule EngramWeb.WellKnownController do
  @moduledoc """
  Serves OAuth 2.1 discovery documents per RFC 8414 (authorization server
  metadata) and RFC 9728 (protected resource metadata).

  Issuer URL is derived from `EngramWeb.Endpoint.url/0`, which resolves
  per-deployment from `PHX_HOST`. Both saas (`app.engram.page`) and selfhost
  (`engram.ax`) thus advertise their own canonical host.
  """
  use EngramWeb, :controller

  def protected_resource(conn, _params) do
    base = base_url()

    payload = %{
      resource: base <> "/api/mcp",
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_documentation: base <> "/docs"
    }

    json(conn, payload)
  end

  def authorization_server(conn, _params) do
    base = base_url()

    payload = %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      revocation_endpoint: base <> "/oauth/revoke",
      response_types_supported: ["code"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: ["none", "client_secret_post"],
      scopes_supported: ["mcp"]
    }

    json(conn, payload)
  end

  defp base_url, do: EngramWeb.Endpoint.url()
end
