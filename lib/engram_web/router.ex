defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]

    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY"
    }
  end

  pipeline :rate_limit_auth do
    plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000
  end

  pipeline :oauth_api do
    plug :accepts, ["json"]
    plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000
  end

  # SPA shell pipeline — HTML responses with strict browser-security headers.
  # x-frame-options=DENY is critical for /oauth/consent: without it the consent
  # UI could be iframed by an attacker site and the approval click hijacked.
  #
  # CSP notes: script-src/style-src use 'unsafe-inline' because SpaController
  # injects a runtime-config <script> into index.html (see
  # EngramWeb.SpaController.config_script/0). TODO: upgrade to per-request
  # nonces and drop 'unsafe-inline' from script-src.
  @csp_policy Enum.join(
                [
                  "default-src 'self'",
                  "script-src 'self' 'unsafe-inline' https://*.clerk.accounts.dev https://*.clerk.com https://challenges.cloudflare.com https://*.paddle.com",
                  "style-src 'self' 'unsafe-inline'",
                  "img-src 'self' data: blob: https:",
                  "font-src 'self' data:",
                  "connect-src 'self' https://*.clerk.accounts.dev https://*.clerk.com https://*.paddle.com",
                  "frame-src https://challenges.cloudflare.com https://*.clerk.accounts.dev https://*.paddle.com",
                  "worker-src 'self' blob:",
                  "form-action 'self'",
                  "base-uri 'self'",
                  "frame-ancestors 'none'"
                ],
                "; "
              )

  pipeline :spa do
    plug :accepts, ["html"]

    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      "content-security-policy" => @csp_policy
    }
  end

  # Paddle webhooks — no auth, raw body for signature verification
  scope "/webhooks", EngramWeb do
    pipe_through :api

    post "/paddle", WebhookController, :paddle
    post "/clerk", WebhookController, :clerk
  end

  # OAuth 2.1 discovery documents — RFC 8414 + RFC 9728. Public, no auth.
  # MCP clients (Claude Connectors, Cursor, ChatGPT custom GPTs, etc.)
  # probe these to learn how to negotiate auth against /api/mcp.
  scope "/.well-known", EngramWeb do
    pipe_through :api

    get "/oauth-protected-resource", WellKnownController, :protected_resource
    get "/oauth-authorization-server", WellKnownController, :authorization_server
  end

  # OAuth 2.1 endpoints — public + rate-limited per IP. Endpoint handlers
  # validate client_id, redirect_uri, and PKCE themselves; no router-level
  # auth. DCR mints public PKCE clients with no `client_secret`.
  scope "/oauth", EngramWeb do
    pipe_through :oauth_api

    post "/register", OAuthRegisterController, :register
    post "/token", OAuthTokenController, :exchange
    post "/revoke", OAuthRevokeController, :revoke
  end

  # OAuth 2.1 user-facing authorize endpoint (RFC 6749 §4.1.1).
  # PUBLIC: browsers hit this via 302 from the OAuth client and do not
  # carry Bearer headers on navigation. The controller validates
  # client_id + redirect_uri + PKCE then 302s to the SPA at
  # /oauth/consent, which mediates consent under the user's existing
  # JWT session.
  scope "/oauth", EngramWeb do
    pipe_through :oauth_api

    get "/authorize", OAuthAuthorizeController, :show
  end

  # All API routes under /api prefix
  scope "/api", EngramWeb do
    # Public endpoints (no auth required, no rate limit)
    pipe_through :api
    get "/health", HealthController, :index
    get "/health/deep", HealthController, :deep
  end

  scope "/api", EngramWeb do
    # Device flow — unauthenticated, rate limited
    pipe_through [:api, :rate_limit_auth]
    post "/auth/device", DeviceAuthController, :start
    post "/auth/device/token", DeviceAuthController, :token
    post "/auth/token/refresh", DeviceAuthController, :refresh
  end

  # Local auth endpoints — always compiled, guarded at runtime by RequireLocalAuth plug
  scope "/api/auth", EngramWeb do
    pipe_through [:api, :rate_limit_auth, EngramWeb.Plugs.RequireLocalAuth]

    post "/register", LocalAuthController, :register
    post "/login", LocalAuthController, :login
    post "/refresh", LocalAuthController, :refresh
    post "/logout", LocalAuthController, :logout
  end

  # User-scoped authenticated endpoints (no vault context needed)
  scope "/api", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth, EngramWeb.Plugs.RotationLockCheck]

    # User info
    get "/user/storage", StorageController, :index
    get "/me", UsersController, :me

    # Device flow authorization (authenticated — web app confirms)
    post "/auth/device/authorize", DeviceAuthController, :authorize

    # API key management — session/JWT only. An API key (especially a
    # vault-restricted one) must never be able to enumerate, mint, or
    # revoke other API keys for the same user.
    scope "/" do
      pipe_through EngramWeb.Plugs.RequireSession
      get "/api-keys", AuthController, :list_api_keys
      post "/api-keys", AuthController, :create_api_key
      delete "/api-keys/:id", AuthController, :revoke_api_key
    end

    # Vault management (user-level, not vault-scoped)
    get "/vaults", VaultsController, :index
    post "/vaults/register", VaultsController, :register
    post "/vaults", VaultsController, :create
    get "/vaults/:id", VaultsController, :show
    patch "/vaults/:id", VaultsController, :update
    delete "/vaults/:id", VaultsController, :delete

    # Billing — Paddle checkout opens client-side via paddle.js, so the
    # backend only exposes status, the public client config, and a portal
    # redirect.
    get "/billing/status", BillingController, :status
    get "/billing/config", BillingController, :config
    get "/billing/portal", BillingController, :customer_portal

    # Onboarding wizard — status + TOS acceptance. Exempt from
    # RequireOnboarding (the plug is only on the vault-scoped pipeline)
    # so the wizard can actually function before completion.
    get "/onboarding/status", OnboardingController, :status
    post "/onboarding/accept-terms", OnboardingController, :accept_terms

    # OAuth consent (Phase 7.A): SPA POSTs here with the user's Bearer
    # JWT after the React consent UI is approved. Returns JSON
    # `{redirect_uri: "..."}` so the SPA can `window.location.assign`.
    post "/oauth/authorize/consent", OAuthAuthorizeController, :consent
  end

  # OAuth public client metadata — surfaces `client_name` to the SPA
  # consent UI without exposing it in the redirect URL bar. Public
  # because client_id is itself public (returned by DCR); client_name
  # is non-secret. Rate-limited per IP to deter enumeration.
  scope "/api/oauth", EngramWeb do
    pipe_through [:api, :rate_limit_auth]

    get "/clients/:client_id", OAuthClientsController, :show
  end

  # Vault-scoped authenticated endpoints (VaultPlug resolves current_vault)
  scope "/api", EngramWeb do
    # RequireOnboarding gates vault access on TOS + active subscription
    # (skipped entirely in self-host mode; see lib/engram/onboarding.ex).
    pipe_through [
      :api,
      EngramWeb.Plugs.Auth,
      EngramWeb.Plugs.DeviceFingerprint,
      EngramWeb.Plugs.RotationLockCheck,
      EngramWeb.Plugs.RequireOnboarding,
      EngramWeb.Plugs.VaultPlug
    ]

    # Notes CRUD
    post "/notes/rename", NotesController, :rename
    post "/notes/append", NotesController, :append
    post "/notes", NotesController, :upsert
    get "/notes/changes", NotesController, :changes
    get "/notes/*path", NotesController, :show
    delete "/notes/*path", NotesController, :delete

    # Metadata
    get "/tags", TagsController, :index
    get "/folders/list", FoldersController, :list
    post "/folders/rename", FoldersController, :rename
    get "/folders", FoldersController, :index

    # Search
    post "/search", SearchController, :search

    # Sync
    get "/sync/manifest", SyncController, :manifest

    # Attachments
    post "/attachments", AttachmentsController, :upload
    get "/attachments/changes", AttachmentsController, :changes
    get "/attachments/*path", AttachmentsController, :show
    delete "/attachments/*path", AttachmentsController, :delete

    # Remote logging
    get "/logs", LogsController, :index
    post "/logs", LogsController, :ingest

    # Embedding status
    get "/embed-status", EmbedStatusController, :index

    # MCP endpoint (JSON-RPC 2.0 over HTTP POST). OAuthScopeEnforce surfaces
    # vault_id/scope claims from OAuth-issued JWTs so the controller can lock
    # tool calls to the bound vault.
    scope "/" do
      pipe_through EngramWeb.Plugs.OAuthScopeEnforce
      post "/mcp", McpController, :handle
    end
  end

  # SPA routes — every path here mounts the React app. Whitelisted (not a
  # blanket /*path catch-all) so unknown URLs hit Phoenix's default 404
  # instead of silently rendering an HTML 200 over a typo'd API/OAuth/asset
  # request. Every new top-level SPA route must be added here.
  scope "/", EngramWeb do
    pipe_through :spa

    get "/", SpaController, :index
    get "/sign-in", SpaController, :index
    get "/sign-up", SpaController, :index
    get "/link", SpaController, :index
    get "/search", SpaController, :index
    get "/billing", SpaController, :index
    get "/onboard", SpaController, :index
    get "/onboard/*path", SpaController, :index
    get "/settings", SpaController, :index
    get "/settings/*path", SpaController, :index
    get "/note/*path", SpaController, :index
    get "/oauth/consent", SpaController, :index
    get "/share/*path", SpaController, :index
  end
end
