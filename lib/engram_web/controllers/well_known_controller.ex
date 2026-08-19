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

  alias EngramWeb.OAuthMetadata

  # Edge-cacheable. Both documents are pure functions of (dialed host, deploy):
  # every value is either a compile-time literal or derived from
  # `OAuthMetadata.base_url/1`, which resolves from the Host header against the
  # `:cors_origin` allowlist. No user, no token, no request body. Verified by
  # diffing two live responses byte-for-byte.
  #
  # Without this every MCP client connect (Claude, Cursor, ChatGPT probe these
  # on EVERY connect, before auth) crossed Cloudflare -> ALB -> Fargate to
  # render a constant. Phoenix's default `max-age=0, private, must-revalidate`
  # made that non-negotiable: `private` forbids a shared cache from storing it
  # at all, so the edge reported `cf-cache-status: DYNAMIC` and passed through.
  #
  # The headers themselves are set by the `:public_cacheable` pipeline in the
  # router, shared with `/api/openapi`, NOT here. They belong together because
  # caching these safely requires a second, non-obvious header change (pinning
  # `access-control-allow-origin` to a constant, since the CORS plug otherwise
  # echoes the request Origin into a shared cache entry) — see the long comment
  # on `public_cacheable_headers/2`. Splitting them across two files is how one
  # of the pair gets changed alone.
  #
  # Correctness note that constrains BOTH: the body VARIES BY HOST.
  # Cloudflare's cache key includes the hostname, so `mcp.` and `app.` get
  # separate entries and cannot be crossed. Do not "optimise" this into a
  # host-independent constant, and do not add a Cache Rule that normalises the
  # host out of the cache key.

  # RFC 9728 `resource_documentation` — where a developer is sent to learn how
  # to use this resource. Optional in the spec, which is exactly why a link that
  # does not resolve is worse than no link: a client following it lands nowhere.
  #
  # NOT derived from the request. As `<base>/docs` it resolved nowhere on any
  # deployment we run:
  #
  #   * `mcp.engram.page/docs` -> 404. `HostRewrite` admits only `/api/mcp`,
  #     `/oauth` and `/.well-known/oauth-*` on the dedicated MCP host.
  #   * `app.engram.page/docs` -> 200, but it is the SPA shell. A 200 that is
  #     not documentation is the worse outcome — nothing reports it as broken.
  #   * selfhost serves no `/docs` route at all.
  #
  # The docs are published on the marketing site for every deployment, self-host
  # included, so this is a fixed absolute URL. No config knob: there is one set
  # of Engram MCP docs, and a self-hoster's users want that same page.
  @resource_documentation "https://engram.page/docs/mcp"

  def protected_resource(conn, _params) do
    base = OAuthMetadata.base_url(conn)

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
      #
      # Derived in OAuthMetadata, not here: Plugs.McpAuthChallenge points the
      # RFC 9728 §5.1 challenge at the metadata URL for this same resource, and
      # a client aborts if the two disagree. Shared derivation, no drift.
      resource: OAuthMetadata.resource(conn),
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_documentation: @resource_documentation
    })
  end

  def authorization_server(conn, _params) do
    base = OAuthMetadata.base_url(conn)

    json(
      conn,
      %{
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
        scopes_supported: ["mcp"],
        # CIMD (IETF draft-ietf-oauth-client-id-metadata-document). Not cosmetic
        # capability signalling: Anthropic's docs say Claude picks CIMD only when
        # the metadata advertises BOTH `"none"` above and this key, so this line
        # is what moves Claude Code off DCR — and it does NOT silently fall back,
        # so if `Engram.OAuth.Cimd` is broken, new Claude Code connections fail
        # rather than degrade. Existing DCR grants are separate rows and keep
        # working. Backing that out is a revert, not a config change.
        client_id_metadata_document_supported: true
      }
    )
  end
end
