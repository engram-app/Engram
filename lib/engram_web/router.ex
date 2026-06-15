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

  pipeline :require_admin do
    plug EngramWeb.Plugs.RequireAdmin
  end

  # Internal scrape pipeline for the PromEx /metrics endpoint. Fails closed
  # via shared bearer token (see EngramWeb.Plugs.MetricsAuth) so the route
  # is safe even though the path is publicly reachable through the ALB —
  # the Grafana Agent sidecar is the only legitimate caller.
  pipeline :metrics_internal do
    plug :accepts, ["text"]
    plug EngramWeb.Plugs.MetricsAuth
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
  #
  # The CSP allowlist is built at request time by `EngramWeb.CSP.header/0`
  # so per-tenant Clerk custom domains (CLERK_ISSUER=https://clerk.<zone>)
  # flow into script-src / connect-src / frame-src without code edits.
  # Adding a new external integration = one builder function in
  # `EngramWeb.CSP`, not a router diff.
  pipeline :spa do
    plug :accepts, ["html"]

    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY"
    }

    plug :put_csp_header
  end

  defp put_csp_header(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "content-security-policy", EngramWeb.CSP.header())
  end

  # PromEx Prometheus scrape endpoint. Bearer-auth guarded; the
  # Grafana Agent sidecar in the prod ECS task is the only legitimate
  # caller. Token is set via :metrics_auth_token in runtime.exs.
  scope "/" do
    pipe_through :metrics_internal
    forward "/metrics", PromEx.Plug, prom_ex_module: Engram.PromEx
  end

  # Paddle webhooks — no auth, raw body for signature verification
  scope "/webhooks", EngramWeb do
    pipe_through :api

    post "/paddle", WebhookController, :paddle
    post "/clerk", WebhookController, :clerk
    post "/resend", WebhookController, :resend
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

  # Full dependency matrix for humans + Grafana. Admin-gated so the
  # response (which names every dep + its status) is not a public
  # information leak. NOT used by ALB or container HCs.
  scope "/api", EngramWeb do
    pipe_through [:api, EngramWeb.Plugs.Auth, :require_admin]
    get "/health/diagnostics", HealthController, :diagnostics
  end

  scope "/api", EngramWeb do
    # Device flow — unauthenticated, rate limited
    pipe_through [:api, :rate_limit_auth]
    post "/auth/device", DeviceAuthController, :start
    post "/auth/device/token", DeviceAuthController, :token
    post "/auth/token/refresh", DeviceAuthController, :refresh

    # Public: explain why a just-completed sign-up was rejected (multi-account
    # block deletes the Clerk user, so there is no session to authenticate with).
    get "/auth/signup-rejection", SignupRejectionController, :show
  end

  # Local auth endpoints — always compiled, guarded at runtime by RequireLocalAuth plug
  scope "/api/auth", EngramWeb do
    pipe_through [:api, :rate_limit_auth, EngramWeb.Plugs.RequireLocalAuth]

    post "/register", LocalAuthController, :register
    post "/login", LocalAuthController, :login
    post "/refresh", LocalAuthController, :refresh
    post "/logout", LocalAuthController, :logout

    # Public preview — confirms an invite is valid + shows its label before signup.
    get "/invite/:token", LocalAuthController, :invite_preview

    # Public self-host bootstrap probe — drives first-run UX on the sign-in/up pages.
    get "/bootstrap", LocalAuthController, :bootstrap

    # Public reset — the one-time token is itself the credential.
    post "/password/reset", PasswordController, :reset
  end

  # User-scoped authenticated endpoints (no vault context needed)
  scope "/api", EngramWeb do
    pipe_through [
      :api,
      EngramWeb.Plugs.Auth,
      # Gate deleted (410) / suspended (403) accounts off the management plane.
      # A user soft-deleted by the inactivity sweep or admin-suspended still
      # holds a valid JWT; without this they could mint API keys, CRUD vaults,
      # and change billing until token expiry.
      EngramWeb.Plugs.AccountLifecycle,
      EngramWeb.Plugs.RotationLockCheck,
      EngramWeb.Plugs.RequireApiRpsBudget
    ]

    # User info
    get "/user/storage", StorageController, :index
    get "/me", UsersController, :me
    patch "/me", UsersController, :update
    delete "/me", UsersController, :delete

    # Authenticated password change (old + new). Reset (token-gated) is public.
    post "/auth/password/change", PasswordController, :change

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
      get "/connections", ConnectionsController, :index
      delete "/connections/oauth/:client_id", ConnectionsController, :delete_oauth
      delete "/connections/device/:family_id", ConnectionsController, :delete_device
      post "/connections/pat", ConnectionsController, :create_pat
      delete "/connections/pat/:id", ConnectionsController, :delete_pat
    end

    # Vault management (user-level, not vault-scoped)
    get "/vaults", VaultsController, :index
    post "/vaults/register", VaultsController, :register
    post "/vaults", VaultsController, :create
    get "/vaults/:id", VaultsController, :show
    patch "/vaults/:id", VaultsController, :update
    delete "/vaults/:id", VaultsController, :delete
    post "/vaults/:id/restore", VaultsController, :restore
    post "/vaults/:id/purge", VaultsController, :purge

    # Billing — Paddle checkout opens client-side via paddle.js, so the
    # backend only exposes status, the public client config, and a portal
    # redirect.
    get "/billing/status", BillingController, :status
    get "/billing/config", BillingController, :config
    get "/billing/portal", BillingController, :customer_portal
    get "/billing/subscription", BillingController, :subscription_detail
    get "/billing/transactions", BillingController, :transactions
    get "/billing/transactions/:id/invoice", BillingController, :transaction_invoice
    get "/billing/payment-update-transaction", BillingController, :payment_update_transaction
    post "/billing/cancel-subscription", BillingController, :cancel_subscription
    post "/billing/reverse-cancel", BillingController, :reverse_cancel
    post "/billing/plan-change/preview", BillingController, :plan_change_preview
    post "/billing/plan-change/confirm", BillingController, :plan_change_confirm

    # OAuth consent (Phase 7.A): SPA POSTs here with the user's Bearer
    # JWT after the React consent UI is approved. Returns JSON
    # `{redirect_uri: "..."}` so the SPA can `window.location.assign`.
    post "/oauth/authorize/consent", OAuthAuthorizeController, :consent
  end

  # Onboarding scope — same as the user-scoped pipeline above, but WITHOUT
  # `RequireApiRpsBudget`. Free tier defaults `api_rps_cap=0` (Pricing v2 §G),
  # which would 429 the very first onboarding write for any Free user
  # authenticating with an API key — they could never complete onboarding.
  # Onboarding endpoints are bounded by the Auth-pipe rate limit; per-plan
  # RPS gating only applies once the user is past onboarding.
  scope "/api", EngramWeb do
    pipe_through [
      :api,
      EngramWeb.Plugs.Auth,
      EngramWeb.Plugs.AccountLifecycle,
      EngramWeb.Plugs.RotationLockCheck
    ]

    # Onboarding wizard — status + TOS acceptance. Exempt from
    # RequireOnboarding (the plug is only on the vault-scoped pipeline)
    # so the wizard can actually function before completion.
    get "/onboarding/status", OnboardingController, :status
    post "/onboarding/accept-terms", OnboardingController, :accept_terms
    # Free-tier acceptance — Continue with Free CTA in /onboard/billing.
    # Sets `free_tier_accepted_at` (idempotent) and returns updated status.
    post "/onboarding/accept_free_tier", OnboardingController, :accept_free_tier
    # FTUX questionnaire — PATCH (frontend api client has no PUT helper).
    patch "/onboarding/profile", OnboardingController, :set_profile
    post "/onboarding/actions", OnboardingController, :record
  end

  # Self-host admin scope. 404 under Clerk (RequireAdmin gates on local auth);
  # 403 for non-admins. There is no named `:authenticated` pipeline, so we list
  # EngramWeb.Plugs.Auth explicitly. Invite/user routes are added in their own
  # phases (B4/C4); only registration-mode routes exist for now.
  scope "/api/admin", EngramWeb.Admin, as: :admin do
    pipe_through [:api, EngramWeb.Plugs.Auth, :require_admin]

    get "/registration", RegistrationController, :show
    # PATCH (not PUT): the frontend `api` client exposes get/post/patch/del, no put.
    patch "/registration", RegistrationController, :update

    resources "/invites", InviteController, only: [:index, :create, :delete]

    get "/users", UserController, :index
    patch "/users/:id", UserController, :update
    delete "/users/:id", UserController, :delete
    post "/users/:id/password-reset", UserController, :password_reset
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
    # PreAuthRateLimit runs FIRST — before Auth — so 401-loop attacks against
    # any vault-scoped path (notes, search, folders, tags, attachments, logs,
    # sync, mcp) are bucketed per {path-category, ip, jwt-sub-or-anon} and
    # rejected with 429 even when the Bearer token is garbage. Cloudflare
    # cannot count response-conditional (auth-rejected) requests on the Free
    # tier, so this is the only thing standing between an attacker and the
    # auth gate. RequireOnboarding gates vault access on TOS + active
    # subscription (skipped entirely in self-host mode; see
    # lib/engram/onboarding.ex).
    pipe_through [
      :api,
      EngramWeb.Plugs.PreAuthRateLimit,
      EngramWeb.Plugs.Auth,
      EngramWeb.Plugs.AccountDeleted,
      EngramWeb.Plugs.DeviceFingerprint,
      EngramWeb.Plugs.RotationLockCheck,
      EngramWeb.Plugs.RequireOnboarding,
      EngramWeb.Plugs.RequireActiveSubscription,
      EngramWeb.Plugs.BumpActivity,
      EngramWeb.Plugs.RequireApiRpsBudget,
      EngramWeb.Plugs.EnforceSearchCap,
      EngramWeb.Plugs.RequireApiWriteEnabled,
      EngramWeb.Plugs.VaultPlug
    ]

    # Notes CRUD
    post "/notes/rename", NotesController, :rename
    post "/notes/append", NotesController, :append
    post "/notes", NotesController, :upsert
    get "/notes/changes", NotesController, :changes
    get "/notes/by-id/:id", NotesController, :show_by_id
    delete "/notes/by-id/:id", NotesController, :delete_by_id
    get "/notes/*path", NotesController, :show
    delete "/notes/*path", NotesController, :delete

    # Notes + folders batch ops — IdempotencyKey enforces X-Idempotency-Key +
    # replay cache so retries (mobile flaps, double-clicks) don't double-execute.
    # The plug halts with the cached response BEFORE the action runs.
    scope "/" do
      pipe_through EngramWeb.Plugs.IdempotencyKey
      post "/notes/batch", NotesController, :batch_upsert
      post "/notes/batch-delete", NotesController, :batch_delete
      post "/notes/batch-move", NotesController, :batch_move
      post "/folders/batch-delete", FoldersController, :batch_delete
      post "/folders/batch-move", FoldersController, :batch_move
    end

    # Metadata
    get "/tags", TagsController, :index
    get "/folders/explicit", FoldersController, :explicit
    get "/folders/list", FoldersController, :list
    get "/folders/by-id/:id/notes", FoldersController, :list_notes
    post "/folders/rename", FoldersController, :rename
    post "/folders", FoldersController, :create
    get "/folders", FoldersController, :index
    delete "/folders/*path", FoldersController, :delete

    # Search
    post "/search", SearchController, :search

    # Sync
    get "/sync/manifest", SyncController, :manifest

    # Attachments
    post "/attachments", AttachmentsController, :upload
    get "/attachments", AttachmentsController, :index
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

  # MCP transport is POST-only JSON-RPC (see the authed scope above).
  # Streamable-HTTP clients open a GET on the endpoint for a server→client
  # SSE stream, and DELETE to end a session — we offer neither. Answer 405 +
  # Allow here rather than letting GET/DELETE fall through to Phoenix's 404,
  # which clients treat as a missing endpoint and abort. Auth-free on
  # purpose: an unsupported method is a method-level fact, not an authz one.
  scope "/api", EngramWeb do
    pipe_through :api
    get "/mcp", McpController, :unsupported_transport
    delete "/mcp", McpController, :unsupported_transport
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
    get "/waitlist", SpaController, :index
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
