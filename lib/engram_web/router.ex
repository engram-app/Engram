defmodule EngramWeb.Router do
  use EngramWeb, :router

  pipeline :api do
    plug :accepts, ["json"]

    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      # Phoenix's put_secure_defaults/1 always emits a CSP, and its default is
      # `frame-ancestors 'self'` — which per CSP Level 2 section 7.4.1
      # SUPERSEDES the x-frame-options DENY set right above it. Left implicit,
      # this pipeline claimed DENY and got 'self'. These routes answer JSON, so
      # nothing here is framable anyway; the point is that the header and the
      # effective policy now agree.
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    }
  end

  # Same as `:api` minus content negotiation. Used only by the MCP
  # method-not-allowed routes below: a Streamable-HTTP client opens the
  # server→client stream with `Accept: text/event-stream`, which
  # `plug :accepts, ["json"]` answers 406 — before the controller that would
  # have told it "POST-only". Negotiating a representation for a request we are
  # rejecting on method alone is meaningless, so this pipeline simply does not.
  pipeline :api_any_accept do
    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      # Phoenix's put_secure_defaults/1 always emits a CSP, and its default is
      # `frame-ancestors 'self'` — which per CSP Level 2 section 7.4.1
      # SUPERSEDES the x-frame-options DENY set right above it. Left implicit,
      # this pipeline claimed DENY and got 'self'. These routes answer JSON, so
      # nothing here is framable anyway; the point is that the header and the
      # effective policy now agree.
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    }
  end

  pipeline :rate_limit_auth do
    plug EngramWeb.Plugs.RateLimit, limit: 10, period: 60_000
  end

  # Shared auth / abuse / onboarding / rate-limit stack for authenticated API
  # endpoints. Used by BOTH the vault-scoped REST scope and the MCP scope so a
  # new security control can't be added to one and silently missed on the other.
  # Each scope appends its own tail (VaultPlug for REST; OAuthScopeEnforce for
  # MCP) after this pipeline.
  pipeline :authed_api do
    plug EngramWeb.Plugs.PreAuthRateLimit
    plug EngramWeb.Plugs.Auth
    plug EngramWeb.Plugs.AccountDeleted
    plug EngramWeb.Plugs.DeviceFingerprint
    plug EngramWeb.Plugs.RotationLockCheck
    plug EngramWeb.Plugs.RequireOnboarding
    plug EngramWeb.Plugs.RequireActiveSubscription
    plug EngramWeb.Plugs.BumpActivity
    plug EngramWeb.Plugs.RequireApiRpsBudget
    plug EngramWeb.Plugs.EnforceSearchCap
    plug EngramWeb.Plugs.RequireApiWriteEnabled
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

    # Not all of this pipeline answers JSON. `GET /oauth/authorize` renders
    # HTML on the error paths (OAuthAuthorizeController.render_client_error/2
    # and render_server_error/2 both send `text/html`), so the OAuth entry
    # point was serving framable, sniffable documents with no headers at all.
    #
    # The CSP is set EXPLICITLY, not left to the default. `put_secure_browser_headers/2`
    # runs `put_secure_defaults/1` first and merges your map over it, so it
    # always emits a CSP — Phoenix's default is `frame-ancestors 'self'`, and
    # per CSP Level 2 §7.4.1 `frame-ancestors` SUPERSEDES `x-frame-options` in
    # every browser that supports both. Sending DENY next to a default CSP
    # produces an effective policy of `'self'`: the header says one thing and
    # the browser does another.
    #
    # `default-src 'none'` is exact here rather than merely strict — these
    # pages are a heading and two paragraphs, with no script, style, image or
    # fetch of any kind. It also applies to this pipeline's JSON routes, where
    # a CSP is inert.
    plug :put_secure_browser_headers, %{
      "x-content-type-options" => "nosniff",
      "x-frame-options" => "DENY",
      "referrer-policy" => "origin",
      "content-security-policy" => "default-src 'none'; frame-ancestors 'none'; base-uri 'none'"
    }
  end

  # OpenAPI spec serving — PutApiSpec needs its `module:` option, which a
  # bare `pipe_through` can't supply, so it lives in its own pipeline.
  pipeline :openapi do
    plug OpenApiSpex.Plug.PutApiSpec, module: EngramWeb.ApiSpec
  end

  # Applied to the handful of PUBLIC, UNAUTHENTICATED documents that are pure
  # functions of (dialed host, deploy) and are cached at the Cloudflare edge:
  # the OAuth discovery documents and the OpenAPI spec. One pipeline for all of
  # them so the cache header and the CORS correction below cannot drift apart.
  pipeline :public_cacheable do
    plug :public_cacheable_headers
  end

  # `/api/openapi` is ~72 KB of JSON that `OpenApiSpex.Plug.RenderSpec`
  # re-renders on EVERY request, and it changes only when a deploy changes the
  # spec. It was going out as `max-age=0, private, must-revalidate` (Phoenix's
  # default), so the edge reported `cf-cache-status: DYNAMIC` and every docs
  # page load, API explorer and codegen run crossed Cloudflare -> ALB ->
  # Fargate to rebuild a constant.
  #
  # Safe for the CI drift gate: that gate generates the spec locally with
  # `mix openapi.spec.json` and diffs it against the committed `openapi.json`
  # (verify.yml). It never fetches this endpoint, so a cached copy cannot make
  # it pass on stale content.
  #
  # Same 5 minute TTL as the OAuth discovery documents, deliberately. This
  # payload is far bigger so a longer TTL is tempting, but it buys little: a
  # docs reader fetches it once per page and 5 minutes already covers a
  # browsing session, while a short window keeps a bad deploy from being
  # pinned at the edge.
  #
  # The OTHER header these paths need — a constant
  # `access-control-allow-origin` — is NOT set here. It lives in
  # `EngramWeb.Plugs.CORS`, keyed on PATH, because that is the predicate the
  # edge uses. A router pipeline only runs for a matched ROUTE, so pinning it
  # here left a request under `/.well-known/oauth-` that matches no route
  # getting an echoed Origin on a response the edge already considered
  # cacheable. See the comment on `@cacheable_prefixes` there.
  #
  # This header alone is NOT sufficient at the edge. Cloudflare's default Cache
  # Level only treats known static file extensions as eligible, so these
  # extensionless JSON paths stay `cf-cache-status: DYNAMIC` no matter what we
  # send here. The paired Cache Rule lives in engram-infra
  # (`main/cloudflare/cache.tf`) and is host-scoped to api/mcp, because the same
  # paths return the SPA shell on app/staging. If you see DYNAMIC after
  # deploying, that rule is missing or its host list is wrong — not this header.
  defp public_cacheable_headers(conn, _opts) do
    Plug.Conn.put_resp_header(conn, "cache-control", "public, max-age=300")
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
      "x-frame-options" => "DENY",
      # Mirrors frontend/public/_headers, which covers ONLY the Cloudflare
      # bundle. This pipeline serves the self-hosted SPA, and without the
      # override Phoenix emits its default
      # `strict-origin-when-cross-origin` — which sends the full path
      # same-origin, i.e. `/link?code=` and `/reset-password?token=` ride the
      # Referer of every same-origin subresource, including the lazy route
      # chunk that loads before the page can scrub the URL.
      #
      # Self-host is where this matters MOST: password reset sits behind
      # RequireLocalAuth, so the token flow only exists on this deployment.
      #
      # Only set here. The :api pipelines answer JSON, not documents, and a
      # referrer policy governs requests a document makes.
      "referrer-policy" => "origin"
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
    pipe_through [:api, :public_cacheable]

    get "/oauth-protected-resource", WellKnownController, :protected_resource
    get "/oauth-authorization-server", WellKnownController, :authorization_server

    # RFC 9728 §3.1 inserts the well-known segment BEFORE the resource's path,
    # so a resource at `https://host/api/mcp` publishes here. A strict client
    # derives this URL from the resource it dialed and tries it FIRST; we served
    # only the bare form above, so this 404'd and only clients that also guess
    # the root convention ever reached discovery. Same document either way — on
    # the dedicated MCP host the resource is the bare host (#634), for which the
    # bare form above is already the spec-correct location.
    get "/oauth-protected-resource/api/mcp", WellKnownController, :protected_resource
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

  # OpenAPI spec — public, no auth. Drives the docs site + CI drift gate.
  # No EngramWeb alias on this scope: RenderSpec is an open_api_spex plug,
  # not an Engram controller.
  scope "/api" do
    pipe_through [:api, :openapi, :public_cacheable]
    get "/openapi", OpenApiSpex.Plug.RenderSpec, []
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
      # Stamps app.user_id on the request span right after Auth resolves
      # current_user. No current_vault at this scope, so app.vault_id is
      # simply absent from these spans.
      EngramWeb.Plugs.TraceUserAttrs,
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
      # Stamps app.user_id on the request span (no current_vault at this
      # onboarding scope, so app.vault_id stays absent here too).
      EngramWeb.Plugs.TraceUserAttrs,
      EngramWeb.Plugs.AccountLifecycle,
      EngramWeb.Plugs.RotationLockCheck
    ]

    # Consolidated first-load payload: onboarding + capabilities + vaults
    # (+ billing when enabled) in one round-trip. Sits here (not the
    # vault-scoped pipeline) so the SPA can fetch it before onboarding is
    # complete to learn `next_step`.
    get "/bootstrap", BootstrapController, :show

    # The index counters on their own, so the SPA can refresh the cap banner
    # after a note create/delete without re-running the whole first-load
    # payload. Same pipeline as /bootstrap deliberately: it is seeded from
    # there and must stay reachable under the same conditions.
    get "/index-status", BootstrapController, :index_status

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

    # Client trace beacon ingest. Must work before onboarding completes (the
    # SPA emits render/sync spans from the very first screen), so it lives in
    # this scope rather than the vault-scoped/RequireOnboarding pipeline.
    post "/telemetry/spans", TelemetryController, :create
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
      :authed_api,
      EngramWeb.Plugs.VaultPlug,
      # Runs last so both current_user and current_vault are resolved:
      # stamps app.user_id AND app.vault_id on the request span.
      EngramWeb.Plugs.TraceUserAttrs
    ]

    # Notes CRUD
    post "/notes/rename", NotesController, :rename
    post "/notes/append", NotesController, :append
    post "/notes", NotesController, :upsert
    get "/notes/changes", NotesController, :changes
    get "/notes/by-id/:id", NotesController, :show_by_id
    get "/notes/by-id/:id/backlinks", NotesController, :backlinks
    delete "/notes/by-id/:id", NotesController, :delete_by_id
    # REST /notes/:id/updates + GET /vault/heads DELETED (Phase E3/#1088) — Yjs
    # deltas AND head discovery travel ONLY over the crdt: socket topic now.
    get "/notes/*path", NotesController, :show
    delete "/notes/*path", NotesController, :delete

    # Notes + folders batch ops — IdempotencyKey enforces X-Idempotency-Key +
    # replay cache so retries (mobile flaps, double-clicks) don't double-execute.
    # The plug halts with the cached response BEFORE the action runs.
    scope "/" do
      pipe_through EngramWeb.Plugs.IdempotencyKey
      post "/notes/batch-delete", NotesController, :batch_delete
      post "/notes/batch-move", NotesController, :batch_move
      post "/folders/batch-delete", FoldersController, :batch_delete
      post "/folders/batch-move", FoldersController, :batch_move
      post "/attachments/batch-move", AttachmentsController, :batch_move
      post "/attachments/batch-delete", AttachmentsController, :batch_delete
    end

    # Metadata
    get "/tags", TagsController, :index
    get "/types", TypesController, :index
    get "/folders/explicit", FoldersController, :explicit
    get "/folders/list", FoldersController, :list
    get "/folders/by-id/:id/notes", FoldersController, :list_notes
    post "/folders/rename", FoldersController, :rename
    post "/folders", FoldersController, :create
    get "/folders", FoldersController, :index
    delete "/folders/*path", FoldersController, :delete

    # One read for the whole web file tree. See VaultTreeController's moduledoc
    # for why the per-folder endpoints could not serve this.
    get "/vault/tree", VaultTreeController, :show

    # Search
    post "/search", SearchController, :search

    # Sync
    get "/sync/manifest", SyncController, :manifest

    # Attachments
    post "/attachments", AttachmentsController, :upload
    get "/attachments", AttachmentsController, :index
    get "/attachments/changes", AttachmentsController, :changes
    # rename must come before *path wildcard so it is not swallowed
    post "/attachments/rename", AttachmentsController, :rename
    get "/attachments/*path", AttachmentsController, :show
    delete "/attachments/*path", AttachmentsController, :delete

    # Remote logging
    get "/logs", LogsController, :index
    post "/logs", LogsController, :ingest

    # Embedding status
    get "/embed-status", EmbedStatusController, :index
  end

  # MCP endpoint (JSON-RPC 2.0 over HTTP POST). Same auth / onboarding /
  # rate-limit stack as the vault-scoped API above, but deliberately WITHOUT
  # VaultPlug: McpController resolves the target vault itself (from the tool's
  # vault_id arg or the OAuth scope). VaultPlug would resolve the *default*
  # vault up front and either 404 the whole request when there is no default
  # (deleted default vault, #951) or 403 a restricted key whose permitted set
  # excludes the default — blocking valid clients before the controller's own
  # credential-scoped resolution (#729) can run. OAuthScopeEnforce surfaces the
  # vault_id/scope claims from OAuth-issued JWTs so the controller can honor the
  # bound vault.
  scope "/api", EngramWeb do
    pipe_through [
      :api,
      # BEFORE :authed_api — it must register its before_send callback while the
      # conn is still moving, since Plugs.Auth inside :authed_api halts. The
      # callback runs on halted conns and keys off the status actually sent, so
      # it covers OAuthScopeEnforce's 401s too, not just Auth's.
      EngramWeb.Plugs.McpAuthChallenge,
      :authed_api,
      # No VaultPlug: McpController self-resolves the vault. TraceUserAttrs still
      # stamps app.user_id (app.vault_id stays nil — MCP is multi-vault per
      # connection, so there is no single request-level vault to tag).
      EngramWeb.Plugs.TraceUserAttrs,
      EngramWeb.Plugs.OAuthScopeEnforce
    ]

    post "/mcp", McpController, :handle
  end

  # MCP transport is POST-only JSON-RPC (see the authed scope above).
  # Streamable-HTTP clients open a GET on the endpoint for a server→client
  # SSE stream, and DELETE to end a session — we offer neither. Answer 405 +
  # Allow here rather than letting GET/DELETE fall through to Phoenix's 404,
  # which clients treat as a missing endpoint and abort. Auth-free on
  # purpose: an unsupported method is a method-level fact, not an authz one.
  #
  # `:api_any_accept`, NOT `:api`: the GET that opens the stream carries
  # `Accept: text/event-stream`, and `plug :accepts, ["json"]` 406s it before
  # this controller runs. That made the 405 above unreachable for precisely the
  # clients it exists to serve — observed with Cursor, which falls back to the
  # legacy HTTP+SSE transport and aborts on the 406.
  scope "/api", EngramWeb do
    pipe_through :api_any_accept
    get "/mcp", McpController, :unsupported_transport
    delete "/mcp", McpController, :unsupported_transport
  end

  # SPA routes, every path here mounts the React app. The static entries
  # below are whitelisted (not a blanket /*path catch-all) so unknown URLs
  # hit Phoenix's default 404 instead of silently rendering an HTML 200
  # over a typo'd API/OAuth/asset request. Every new top-level static SPA
  # route must be added here.
  #
  # Below the whitelist, `/:slug` and `/:slug/:id` are dynamic vault-scoped
  # routes (vault, and vault+note-or-attachment). Those are wildcards, so a
  # deny-list for every non-SPA top-level prefix sits between the whitelist
  # and the wildcards; see its comment for why order matters (it must stay
  # BELOW the static whitelist above and ABOVE the wildcards below).
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
    # NOTE: no /share/* route: sharing doesn't exist yet (no /api/share*,
    # no schema, no SPA page). Removed 2026-07-02 (#858) after shipping as a
    # vestigial whitelist entry; re-add alongside the actual feature. (A
    # bare 2-segment /share/:x now falls through to the vault-scoped
    # /:slug/:id route below like any other slug; that's expected, not a
    # revival of this feature.)

    # Deny-list. MUST stay BELOW the static whitelist above (so a real
    # static route like /oauth/consent still wins over its own prefix's
    # deny entry) and ABOVE the dynamic /:slug routes below (those are
    # 1- and 2-segment wildcards, so without this a typo'd /api/notez would
    # match /:slug/:id and serve an HTML 200, the exact regression #858
    # removed). EVERY new non-SPA top-level prefix must be added here.
    match :*, "/api/*path", SpaController, :not_found
    match :*, "/oauth/*path", SpaController, :not_found
    match :*, "/webhooks/*path", SpaController, :not_found
    match :*, "/.well-known/*path", SpaController, :not_found
    # /socket is registered by the `socket "/socket", EngramWeb.UserSocket`
    # macro in endpoint.ex, not a router scope, so it doesn't show up when
    # enumerating scope declarations either. Endpoint-level socket dispatch
    # only claims the exact transport subpath (/socket/websocket); every
    # other /socket/* request (bare /socket, typos, /socket/origin-probe
    # without its own /websocket suffix) falls through to the router same as
    # /assets and /email. HostRewrite already treats /socket as a first-class
    # top-level prefix (@api_allowed_prefixes in host_rewrite.ex); the SPA
    # deny-list needs the same entry for the same reason.
    match :*, "/socket/*path", SpaController, :not_found
    # /assets isn't a router scope (it's Plug.Static mounted in
    # endpoint.ex), so it's easy to miss here. Plug.Static only intercepts
    # requests for files that exist; a mistyped/missing asset path falls
    # through to the router and, without this entry, would match
    # /:slug/:id and serve an HTML 200 for a broken <script src>.
    match :*, "/assets/*path", SpaController, :not_found
    # /email is also Plug.Static-served (see static_paths() in
    # lib/engram_web.ex), same pass-through-on-miss shape as /assets. These
    # paths are embedded in outbound email HTML and fetched by third-party
    # mail proxies (Gmail image proxy, etc.), which may cache a 200 response.
    # A masked HTML 200 there is worse than the usual case: the bad result
    # can get cached remotely, not just seen once by a browser.
    match :*, "/email/*path", SpaController, :not_found

    # The remaining EngramWeb.static_paths/0 entries are single-segment, so they
    # need exact matches rather than the /prefix/*path shape above. Plug.Static
    # only serves files that exist; on a miss (broken build, deploy skew) these
    # would otherwise fall through to get "/:slug" and return an HTML 200.
    match :*, "/favicon.ico", SpaController, :not_found
    match :*, "/favicon.svg", SpaController, :not_found
    match :*, "/engram-mark.svg", SpaController, :not_found
    match :*, "/robots.txt", SpaController, :not_found

    # Vault-scoped SPA routes. `/:slug` is a vault, `/:slug/:id` a note or
    # attachment. Kept last so every static route and the deny-list above
    # wins.
    get "/:slug", SpaController, :index
    get "/:slug/:id", SpaController, :index
  end
end
