# MCP OAuth 2.1 + Dynamic Client Registration

## Context

Claude desktop / web / mobile have a **Connectors** UI where a user pastes a remote MCP server URL and the app handles auth automatically. That auto-auth requires the MCP server to expose **OAuth 2.1 with Dynamic Client Registration (DCR)** plus two `.well-known/` discovery documents. Engram's MCP endpoint (`POST /api/mcp` on `app.engram.page`) currently only accepts `Authorization: Bearer <api_key>` or Clerk JWT — neither of which Connectors UI knows how to negotiate. Result: a user trying to add `https://app.engram.page/api/mcp` gets `{"error":"unauthorized"}` with no way to authenticate.

Goal: stand up a minimal, spec-compliant OAuth 2.1 + DCR authorization server inside the Engram backend so Claude Connectors can complete the flow against both `app.engram.page` (saas, Clerk identity) and `engram.ax` (selfhost, local identity). Token model lets the user pick a single vault or all vaults at consent time.

**Strategic note:** OAuth on `/api/mcp` is the *integration plane* for any standards-compliant tool — not just Claude. After this ships, Cursor / Continue / Cline / ChatGPT custom GPTs / Zapier / Make / n8n / IFTTT / future MCP+OAuth clients all integrate without per-provider code. Single highest-leverage piece of integration infra Engram can ship for ecosystem reach.

**Out of scope:** the Obsidian plugin's auth. Plugin already uses `Engram.Auth.DeviceFlow` (OAuth-shaped, just not RFC-named) — different threat model (first-party trusted client) and migrating is churn for ~zero security gain. Could be revisited as a separate consistency-pass later, but not coupled to this work.

Side task: workspace memory + a few code/test/deploy comments still reference the old `engram-sync.app` / `engram.ras.band` domain. Update during this work.

---

## Educational Primer

Skip if you already know OAuth — but the user said they don't, so here's the minimum mental model.

### What Claude Connectors actually does (the wire flow)

When you click "Add Connector" and paste `https://app.engram.page/api/mcp`:

1. **Resource discovery.** Claude `GET`s `https://app.engram.page/.well-known/oauth-protected-resource`. This tiny JSON document tells Claude *"my authorization server lives at `https://app.engram.page` — go ask it for tokens."* (RFC 9728)
2. **Auth-server discovery.** Claude `GET`s `https://app.engram.page/.well-known/oauth-authorization-server`. This document lists what the auth server supports: which endpoints exist, which grant types, that PKCE is required, etc. (RFC 8414)
3. **Self-registration (DCR).** Claude `POST`s `/oauth/register` with its own metadata: redirect URIs, client name, scopes it wants. The server mints a `client_id` and returns it. Claude has now "registered itself" — no human admin involved. (RFC 7591)
4. **Authorization request.** Claude opens a browser to `/oauth/authorize?response_type=code&client_id=...&redirect_uri=...&code_challenge=...&scope=mcp`. The server (Engram) checks the user is logged in (Clerk on saas, local on selfhost), shows a consent screen ("Claude wants to access your Engram vault — pick one"), user clicks Approve.
5. **Code returned.** Server redirects back to Claude's `redirect_uri` with `?code=abc123`.
6. **Token exchange.** Claude `POST`s `/oauth/token` with the code + the PKCE `code_verifier`. Server verifies the verifier hashes to the `code_challenge` from step 4, then issues an `access_token` + `refresh_token`.
7. **Steady state.** Claude calls `POST /api/mcp` with `Authorization: Bearer <access_token>`. Token expires in ~1h; Claude swaps refresh token for new access token via `/oauth/token` again.

### Why each piece exists

- **PKCE** (Proof Key for Code Exchange): the `code` from step 5 travels through a browser — interceptable. PKCE forces whoever redeems the code in step 6 to also know the original secret (`code_verifier`) that hashed to the `code_challenge` in step 4. Stops a thief who steals the code mid-redirect.
- **DCR**: classical OAuth required the user to manually register their app and copy/paste a `client_id`. Connectors UI can't do that — so MCP requires DCR so any client can self-register on the fly.
- **Two discovery documents instead of one**: RFC 9728 splits "I am a protected resource, my auth server is X" from "I am the auth server, here's how I work" — so a resource server and auth server can be on different hosts. Engram puts them on the same host but the spec still requires both files.

### Engram's existing analog

`Engram.Auth.DeviceFlow` (`backend/lib/engram/auth/device_flow.ex`) is essentially OAuth 2.0 device-code flow without strict spec compliance. It already has: pending/authorized/consumed state, hashed refresh tokens, expiry. We mirror its data shape for the OAuth grant — same playbook, different endpoints + spec-required fields.

### Token format choice

Access tokens are issued as the **existing internal HS256 JWT** (`Engram.Accounts.generate_jwt/1`). `Engram.Auth.TokenResolver` already validates these as the third fallback path. Net new validation code in the auth plug: zero. We only add a new resolver for refresh tokens (which are opaque `engram_rt_*` strings, same format the device flow already uses).

---

## Architecture

### New tables

| Table | Purpose | Key columns |
|-------|---------|-------------|
| `oauth_clients` | One row per DCR-registered client | `client_id` (UUID), `client_secret_hash` (nullable for public clients), `redirect_uris` (text[]), `client_name`, `scope`, `created_at` |
| `oauth_authorization_codes` | Short-lived (10min) codes from `/oauth/authorize` | `code_hash`, `client_id`, `user_id`, `redirect_uri`, `code_challenge`, `code_challenge_method`, `scope`, `vault_id` (nullable when scope=`vault:*`), `expires_at`, `consumed_at` |
| `oauth_refresh_tokens` | Long-lived (90d) refresh tokens | `token_hash`, `client_id`, `user_id`, `vault_id` (nullable), `scope`, `expires_at`, `revoked_at` |

We do NOT issue an access-token row in DB — access tokens are stateless JWTs validated by `TokenResolver`. (Trade-off: can't revoke an access token mid-life. Mitigated by short TTL; revocation is via refresh-token revoke.)

### New endpoints

| Method + path | Auth | What it does |
|---------------|------|--------------|
| `GET /.well-known/oauth-protected-resource` | none | Static JSON: `{resource, authorization_servers}` |
| `GET /.well-known/oauth-authorization-server` | none | Static JSON: server metadata (issuer, endpoints, grant_types, PKCE algs) |
| `POST /oauth/register` | none (open DCR) | Mints client. Rate-limited per IP. Returns `client_id` + (optional) `client_secret`. |
| `GET /oauth/authorize` | session (Clerk on saas, local on selfhost) | Renders consent page if logged in; redirects to login otherwise then back. |
| `POST /oauth/authorize` | session | Records consent, generates code, 302 to `redirect_uri?code=...` |
| `POST /oauth/token` | client cred + PKCE | Exchanges code → tokens; or refresh → tokens |
| `POST /oauth/revoke` | client cred | Revokes refresh token (RFC 7009) |

### Pipeline placement (router.ex)

New `:oauth_browser` pipeline (browser plug + `RequireSession` for `/oauth/authorize` GET/POST) and `:oauth_api` pipeline (API only, no auth — endpoints validate client creds + PKCE themselves). Mounts BEFORE the existing `:api` scope so they don't get caught by the SPA fallback.

### Auth provider abstraction

Both saas and selfhost get OAuth from day 1. The consent controller uses `RequireSession` plug which already works on both providers (`EngramWeb.Plugs.RequireSession` checks Clerk JWT *or* local session cookie). The consent template renders the user's email from `conn.assigns.current_user.email` — provider-agnostic. No fork.

### Scope grammar

Three scopes minted at consent time:
- `mcp` — required, identifies this as an MCP-server token (vs general-purpose).
- `vault:<uuid>` — bound to one vault. Token's MCP tool calls force `vault_id = <uuid>`.
- `vault:*` — all user's vaults. Tool calls choose vault per-call (existing arg).

Consent screen offers a vault picker: "this vault" → `vault:<uuid>`, "all vaults" → `vault:*`. Stored on `oauth_authorization_codes.scope` and propagated to refresh token.

### MCP plug change

`EngramWeb.Plugs.Auth` stays unchanged for token validation (TokenResolver handles the JWT). New thin plug `EngramWeb.Plugs.OAuthScopeEnforce` mounted only on `/api/mcp` reads the validated JWT's scope claim, sets `conn.assigns.oauth_scope`, and the `McpController.resolve_mcp_vault/3` enforces `vault:<uuid>` lock if present.

JWT must carry `scope` claim. Add `scope` arg to `Accounts.generate_jwt/2` (default `nil`).

---

## Phases (TDD-ordered, each phase = one PR)

### Phase 0 — Domain doc cleanup *(prep, ~30 min, PR #1)*

Update stale references to `engram-sync.app` / `engram.ras.band` / etc. → `app.engram.page`. From explore agent's scan:

- `backend/config/dev.exs:44` — comment
- `backend/lib/engram/host_origins.ex:6` — docstring
- `backend/test/engram/host_origins_test.exs` — fixture domains (verify intent: these may legitimately test the parser with multiple hosts; only change if they're meant to represent canonical prod)
- `backend/test/engram_web/endpoint_config_test.exs`
- `backend/test/engram_web/plugs/cors_test.exs`
- `plugin/tests/auth-state.test.ts`
- `backend/deploy/fastraid-deploy.sh:5-6` — deployment comments
- Memory files: `~/.claude/projects/.../MEMORY.md` entries calling out `engram-sync.app` / `engram.ras.band`
- `docs/context/fastraid-deploy.md` (uses IP, fine — but cross-check)

Standalone commit, no spec work.

### Phase 1 — Discovery documents *(~1 day, PR #2)*

Smallest-possible spec touchpoint. Build `/.well-known/oauth-protected-resource` and `/.well-known/oauth-authorization-server` as static JSON responses from a new `EngramWeb.WellKnownController`. No DB changes, no DCR yet.

**Why first:** lets us point Claude Connectors at the URL and watch DevTools to see exactly what the next request shape looks like — drives PR #3 details from real wire traffic, not assumptions. Also, having `.well-known` live first means Phase 2's tests can probe it.

Files:
- new: `lib/engram_web/controllers/well_known_controller.ex`
- modify: `lib/engram_web/router.ex` (mount routes)
- new: `test/engram_web/controllers/well_known_controller_test.exs`

TDD: test asserts the JSON shape per RFC 8414 + 9728 (required fields: `issuer`, `authorization_endpoint`, `token_endpoint`, `registration_endpoint`, `code_challenge_methods_supported: ["S256"]`, `grant_types_supported: ["authorization_code", "refresh_token"]`). Endpoints can return `404` for now — discovery still must point to them.

### Phase 2 — DCR endpoint *(~1 day, PR #3)*

`POST /oauth/register` + `oauth_clients` table. Per RFC 7591: accepts JSON `{redirect_uris, client_name, scope, ...}`, returns `client_id` (UUID) + `client_id_issued_at`. For Connectors we can mint **public clients** (no secret) since they use PKCE — RFC 7591 §3.2.1 allows this.

Files:
- new migration: `priv/repo/migrations/<ts>_create_oauth_clients.exs`
- new schema: `lib/engram/oauth/client.ex`
- new context: `lib/engram/oauth.ex` (high-level register/lookup functions)
- new controller: `lib/engram_web/controllers/oauth_register_controller.ex`
- modify: `router.ex` (add `:oauth_api` pipeline + route)
- modify: `well_known_controller.ex` (registration_endpoint now resolves)
- new test: `test/engram_web/controllers/oauth_register_controller_test.exs` — happy path + invalid `redirect_uris` + rate limit

Add rate limit: reuse existing `EngramWeb.Plugs.RateLimit` (Phase C work) at 10 reg/IP/min.

### Phase 3 — Authorization endpoint + consent UI *(~2 days, PR #4)*

`GET /oauth/authorize` — validates `client_id`, `redirect_uri` (exact match against registered URIs), `response_type=code`, `code_challenge`, `code_challenge_method=S256`, `state`. If user not logged in → redirect to existing login flow with return URL. If logged in → render consent template.

`POST /oauth/authorize` — handles consent submission; user picks vault scope; mints authorization code; redirects to `redirect_uri?code=...&state=...`.

Files:
- new migration: `priv/repo/migrations/<ts>_create_oauth_authorization_codes.exs`
- new schema: `lib/engram/oauth/authorization_code.ex`
- new context fns in `Engram.OAuth`: `start_authorization/2`, `consent/3`, `consume_code/3`
- new controller: `lib/engram_web/controllers/oauth_authorize_controller.ex`
- new template: `lib/engram_web/controllers/oauth_authorize_html/consent.html.heex` — lists user's vaults, "this vault" / "all vaults" radio
- modify `router.ex`: add `:oauth_browser` pipeline pulling in `RequireSession`
- new tests: cover invalid client_id, mismatched redirect_uri, no PKCE → reject, happy path code mint

Reuse: `Vaults.list_user_vaults/1` for picker, `RequireSession` for auth, `LayoutView` for chrome.

### Phase 4 — Token endpoint *(~2 days, PR #5)*

`POST /oauth/token` — handles two grant types:

1. `grant_type=authorization_code` — verify code unconsumed + unexpired + matching client_id + matching redirect_uri + PKCE verifier hashes to challenge. On success: mint internal JWT (with `scope` claim), mint refresh token, mark code consumed.
2. `grant_type=refresh_token` — verify refresh token unrevoked + unexpired. On success: rotate (revoke old, mint new — RFC 6749 §10.4 best practice), mint new access JWT.

Files:
- new migration: `priv/repo/migrations/<ts>_create_oauth_refresh_tokens.exs`
- new schema: `lib/engram/oauth/refresh_token.ex`
- new controller: `lib/engram_web/controllers/oauth_token_controller.ex`
- modify `lib/engram/accounts.ex` — `generate_jwt/2` accepts optional `scope` and `vault_id` claims
- new tests: PKCE pass/fail, code reuse rejected, code_verifier mismatch rejected, refresh rotation, expired token rejected

Reuse: refresh-token hashing pattern from `DeviceFlow.create_refresh_token/2`. Likely extract into `Engram.Auth.TokenHash` shared module if duplication starts to itch.

### Phase 5 — MCP scope enforcement *(~1 day, PR #6)*

Tokens now flow end-to-end. Lock down `/api/mcp` so a `vault:<uuid>`-scoped token cannot call tools against a different vault.

Files:
- new plug: `lib/engram_web/plugs/oauth_scope_enforce.ex` — reads JWT scope from `conn.assigns`, sets `conn.assigns.oauth_scope_vault`
- modify `lib/engram_web/controllers/mcp_controller.ex` — `resolve_mcp_vault/3` enforces vault lock when scope is `vault:<uuid>`
- modify `router.ex` — mount `OAuthScopeEnforce` after `Auth` on the MCP scope only
- modify `lib/engram/auth/token_resolver.ex` — surface `scope` claim from internal JWT
- new tests: scoped token + matching vault = pass; scoped token + different vault = 403; unscoped token = backward-compat pass

### Phase 6 — Revocation + cleanup *(~0.5 day, PR #7)*

`POST /oauth/revoke` (RFC 7009). Cleanup cron extension to drop expired authorization codes + revoked refresh tokens > 7d. Update `Engram.Auth.DeviceFlow.cleanup_expired/0` to also handle OAuth tables (or extract to shared `Engram.Auth.Cleanup`).

### Phase 7 — Live test against Claude Connectors *(~0.5 day, no PR)*

Add `https://app.engram.page/api/mcp` in Claude desktop Connectors UI. Walk the flow. Capture:
- Wire trace via Phoenix request logger (with redaction filter — RedactFilter is already in place, but add `code_challenge` / `code_verifier` to redaction list as belt-and-suspenders)
- Fix any spec-compliance gaps Connectors highlights

### Phase 8 — Self-host parity smoke test *(~0.5 day)*

Same flow against `https://engram.ax/api/mcp`. Verify local-auth consent path works. Document any divergence in `docs/context/`.

### Phase 9 — Cross-client conformance *(~1 day, no PR — findings may spawn fix PRs)*

Don't trust "Claude works" as proof of standards compliance — Connectors UI is permissive. Run the same flow from at least 3 other clients to verify we're not Claude-specific:

1. **Cursor** (free, MCP-native IDE) — add Engram as MCP server, walk OAuth.
2. **Continue.dev** (open source MCP client) — same.
3. **ChatGPT custom GPT with Actions** — wire OpenAPI schema pointing at `/api/mcp`, OAuth via the same discovery docs. Confirms baseline OAuth 2.0/2.1 compliance.
4. *Optional:* **Zapier OAuth source** — if approval flow is fast. Confirms non-MCP OAuth integrations.

For each client, capture the wire trace and note any spec divergence (e.g. expected `expires_in` format, missing `aud` claim handling, redirect_uri whitelist quirks). File spec-fix PRs as needed.

### Phase 10 — Documentation *(~0.5 day, can be folded into earlier PRs)*

- New `docs/context/mcp-oauth.md` covering the flow + how to add a new client manually + how to revoke
- Update `docs/api-contract.md` with the OAuth endpoints
- Update `backend/CLAUDE.md` with one-liner pointer
- Add user-facing docs page (Marketing site or docs route) — "Connect any AI tool to your Engram" (intentionally generic, not Claude-specific) with subsections per major client (Claude, Cursor, ChatGPT, etc.)

---

## Critical files to read before each phase

- Phase 1: `lib/engram_web/router.ex` (routing conventions), `lib/engram_web/controllers/marketing_controller.ex` (pattern for static-render controllers)
- Phase 2: `lib/engram/accounts.ex:295-321` (`create_api_key`/`validate_api_key` pattern), `lib/engram_web/plugs/rate_limit.ex`
- Phase 3: `lib/engram_web/plugs/require_session.ex`, `lib/engram/auth/device_flow.ex` (full file — closest analog), `lib/engram/vaults.ex` (vault list)
- Phase 4: `lib/engram/auth/device_flow.ex:74-96` (code consume), `lib/engram/auth/device_flow.ex:98-127` (refresh rotation), `lib/engram/accounts.ex` (`generate_jwt`)
- Phase 5: `lib/engram_web/plugs/auth.ex`, `lib/engram_web/controllers/mcp_controller.ex` (esp. `resolve_mcp_vault/3`)
- Phase 6: `lib/engram/auth/device_flow.ex:129-145` (cleanup pattern)

---

## Verification

### Per-phase

Each phase's PR has unit tests that must pass `mix test`. Phase 1-6 PRs also keep `make plugin-test` and `make e2e-unit` green (no plugin / E2E impact expected).

### End-to-end (after Phase 5)

Manual test from Claude desktop:
1. Settings → Connectors → Add → paste `https://app.engram.page/api/mcp`
2. Browser opens → Engram consent screen → pick "this vault" → Approve
3. Returns to Claude; Connector shows green
4. Ask Claude: *"List my notes in Engram"* — should hit `/api/mcp` with `tools/call list_notes`, return notes from chosen vault
5. Try same flow on `https://engram.ax` from a fresh browser session

### Spec compliance probes

Curl scripts saved as `backend/scripts/oauth-smoke.sh`:
```bash
# Discovery
curl https://app.engram.page/.well-known/oauth-protected-resource | jq .
curl https://app.engram.page/.well-known/oauth-authorization-server | jq .
# DCR
curl -X POST https://app.engram.page/oauth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:9999/cb"],"client_name":"smoke"}' | jq .
# Token endpoint shape (will fail auth; we're just checking it responds)
curl -X POST https://app.engram.page/oauth/token -d 'grant_type=authorization_code&code=x'
```

### Security

- Penetration tests: code reuse → 400; mismatched redirect_uri → 400; missing PKCE → 400; expired code → 400; revoked refresh token → 400
- Rate limit: hammer `/oauth/register` 11x in 1min, expect 429 on 11th
- Cross-tenant: client A token used to call MCP with vault B's id → 403

---

## Open questions to revisit before Phase 4

- **Refresh token rotation policy on reuse detection.** RFC 6749 §10.4 recommends revoking the *whole token family* on detected reuse (someone replayed an old refresh token). Worth adding in Phase 4 or deferring to Phase 6? Lean: Phase 4, since the migration would touch the same table.
- **Consent screen — remember consent?** First version always shows consent. RFC 6749 doesn't require remembering, but UX-wise we may want a "always allow Claude" checkbox later. Defer.
- **Audience claim (`aud`) in access JWT.** Add `aud=https://app.engram.page/api/mcp` so a token issued for MCP can't be confused with an internal JWT for, say, billing endpoints. Lean: yes, add in Phase 4.
