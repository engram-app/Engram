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
      # The advertised `resource` must be the URL at which THIS host actually
      # serves MCP — RFC 9728 lets us advertise only one, and strict clients
      # bind the token audience to it (and self-check it == the dialed URL).
      #
      #   * saas dedicated MCP host (`mcp.engram.page`): HostRewrite maps the
      #     bare root `/` → `/api/mcp`, so the canonical resource is the BARE
      #     host. Users paste `https://mcp.engram.page` (no path); advertising
      #     the path here made strict clients (Claude Code CLI) abort on the
      #     mismatch. See Engram#634.
      #   * everything else (selfhost `engram.ax`, `app`/`api` hosts): no MCP
      #     rewrite — bare `/` is the SPA and MCP lives only at `/api/mcp`, so
      #     the resource MUST keep the path or self-host clients would mismatch.
      #
      # Token `aud` is the fixed string "engram" (see Engram.Token), independent
      # of this URL, so either form breaks no server-side audience check.
      resource: if(mcp_rewrite_host?(conn), do: base, else: base <> "/api/mcp"),
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_documentation: base <> "/docs"
    })
  end

  # True only when the dialed host is the saas dedicated MCP host that
  # HostRewrite serves at the bare root (`:host_rewrite` config sets `mcp_host`).
  # Selfhost leaves `:host_rewrite` unset → always false → path form.
  defp mcp_rewrite_host?(conn) do
    case Application.get_env(:engram, :host_rewrite, []) do
      opts when is_list(opts) -> opts[:mcp_host] != nil and conn.host == opts[:mcp_host]
      _ -> false
    end
  end

  def authorization_server(conn, _params) do
    base = base_url(conn)

    json(
      conn,
      maybe_advertise_cimd(%{
        issuer: base,
        authorization_endpoint: base <> "/oauth/authorize",
        token_endpoint: base <> "/oauth/token",
        registration_endpoint: base <> "/oauth/register",
        revocation_endpoint: base <> "/oauth/revoke",
        response_types_supported: ["code"],
        grant_types_supported: ["authorization_code", "refresh_token"],
        code_challenge_methods_supported: ["S256"],
        # `none` MUST stay first-class here, not merely present for legacy: Claude
        # selects its CIMD flow only when this list contains "none", and would
        # otherwise fall back to DCR. The secret-based methods are additive, for
        # server-side connectors that cannot hold a public client.
        token_endpoint_auth_methods_supported: [
          "none",
          "client_secret_post",
          "client_secret_basic"
        ],
        scopes_supported: ["mcp"]
      })
    )
  end

  # Advertised only when CIMD is switched on, and the flag defaults to off.
  #
  # This is not cosmetic capability signalling: Anthropic's docs say Claude picks
  # CIMD only when the metadata advertises BOTH `"none"` in
  # token_endpoint_auth_methods_supported (above) and this key. Adding it flips
  # Claude Code off the DCR path immediately, with no silent fallback if our CIMD
  # path is broken — so it is gated rather than shipped on. See
  # `Engram.OAuth.Cimd.enabled?/0`.
  #
  # Absent rather than `false` when disabled: the draft treats the key as opt-in
  # capability advertisement, and an explicit false invites a client to cache a
  # negative answer past the point where we flip it on.
  defp maybe_advertise_cimd(metadata) do
    if Engram.OAuth.Cimd.enabled?(),
      do: Map.put(metadata, :client_id_metadata_document_supported, true),
      else: metadata
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
