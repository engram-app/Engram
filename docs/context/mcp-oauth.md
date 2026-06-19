# MCP OAuth 2.1 + DCR — How It Works

End-to-end OAuth 2.1 + Dynamic Client Registration on Engram's MCP endpoint, so Claude Connectors / Cursor / ChatGPT custom GPTs / any other standards-compliant client can auto-auth against `mcp.engram.page/api/mcp` (saas) or `engram.ax/api/mcp` (selfhost) without per-client integration code.

> **Host note:** the saas MCP endpoint is `mcp.engram.page`, NOT `app.engram.page`. The `host_rewrite.ex` plug rejects `/api/mcp` and `/oauth/*` on `app.engram.page` (old path now 405s). All curl examples below use `mcp.engram.page`.

Shipped in PRs #91-#97 across 6 backend phases (Phase 0-6) plus the docs PR. Phases 7.A/7.B/7.C and the SPA consent page are also shipped.

## Wire flow (what Claude Connectors actually does)

```
1. GET  /.well-known/oauth-protected-resource    → {resource, authorization_servers}
2. GET  /.well-known/oauth-authorization-server  → endpoints + grant_types + PKCE
3. POST /oauth/register                          → mints client_id (DCR)
4. GET  /oauth/authorize?client_id&redirect_uri  → 302 to /oauth/consent (SPA mediation, Phase 7.A)
5. SPA reads URL params, fetches /api/oauth/clients/:id for client_name, renders consent
6. POST /api/oauth/authorize/consent {vault_choice} → JSON {redirect_uri: "..."} (SPA window.location)
7. POST /oauth/token grant=authorization_code    → access_token + refresh_token
8. POST /api/mcp Authorization: Bearer ...       → tool calls (vault-locked)
9. POST /oauth/token grant=refresh_token         → rotated tokens (RFC 6749 §10.4 family)
10. POST /oauth/revoke                           → 200 always (RFC 7009)
```

## Endpoint reference

| Method + path | Auth | Purpose |
|---------------|------|---------|
| `GET /.well-known/oauth-protected-resource` | none | RFC 9728 — points clients at `/api/mcp` + lists auth server |
| `GET /.well-known/oauth-authorization-server` | none | RFC 8414 — server metadata (endpoints, grant types, PKCE S256, scopes) |
| `POST /oauth/register` | none, rate-limited 10/IP/min | RFC 7591 DCR — public PKCE clients only (no `client_secret`) |
| `GET /oauth/authorize` | none, rate-limited 10/IP/min | Validates request, 302s to `/oauth/consent` (SPA mediation, Phase 7.A) |
| `GET /api/oauth/clients/:client_id` | none, rate-limited 10/IP/min | Public client metadata — `{client_id, client_name}` only, for SPA consent UI |
| `POST /api/oauth/authorize/consent` | Bearer JWT | SPA submits w/ `vault_choice`. Mints code. JSON `{redirect_uri: "..."}` for SPA `window.location` |
| `POST /oauth/token` | none, rate-limited 10/IP/min | RFC 6749 §3.2 — auth code → tokens, refresh → rotated tokens |
| `POST /oauth/revoke` | none, rate-limited 10/IP/min | RFC 7009 — 200 always |

## Token model

- **Access token** — internal HS256 JWT minted by `Engram.Accounts.generate_jwt/2` with optional `scope` + `vault_id` claims. 15-min TTL. Stateless (no DB row, can't revoke mid-life — short TTL is the mitigation). `EngramWeb.Plugs.Auth` validates via `TokenResolver`'s third fallback path (already existed pre-OAuth for the device flow).
- **Refresh token** — `engram_oauth_rt_<...>` opaque random, sha256-hashed at rest. 90-day TTL. Stored in `oauth_refresh_tokens` with a `family_id` per RFC 6749 §10.4. Rotation on use; replay of a consumed token revokes the entire family.

## Scope grammar

Three values minted at consent:
- `mcp` — required, identifies as MCP-server token (vs general-purpose internal JWT)
- `vault:<id>` — bound to one vault. Any tool call with a different `vault_id` arg is rejected by `EngramWeb.Plugs.OAuthScopeEnforce` + `McpController.resolve_mcp_vault/3`.
- `vault:*` — all user's vaults. Tool calls choose `vault_id` per-call.

Scope is propagated through code → refresh token → access JWT. Today the JWT carries `vault_id` as a separate claim (not parsed from the scope string) — simpler enforcement, same effect.

## How to add a client manually (for debugging / local CLI scripts)

```bash
# Register via DCR — no admin involvement
curl -X POST https://mcp.engram.page/oauth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:9999/cb"],"client_name":"my-cli"}'

# Returns {"client_id":"<uuid>","client_id_issued_at":..., ...}
```

Use the returned `client_id` in a normal authorize → token flow. PKCE is mandatory.

## How to revoke a refresh token

```bash
curl -X POST https://mcp.engram.page/oauth/revoke \
  -H "Content-Type: application/json" \
  -d '{"token":"engram_oauth_rt_...","client_id":"<uuid>"}'
```

Always returns 200 per RFC 7009 §2.2. If `client_id` doesn't own the token, it's a silent no-op (token survives — leaking the distinction would help an attacker enumerate live tokens). Revoking a token in a refresh family also burns the rest of the family if any consumed-or-revoked replay is later detected.

## Database schema

| Table | Tenanted? | Purpose |
|-------|-----------|---------|
| `oauth_clients` | No (shared, pre-login) | DCR-registered clients, PK `client_id` (UUID) |
| `oauth_authorization_codes` | No (looked up by hashed code, pre-token) | One-time codes, 10-min TTL, sha256-hashed |
| `oauth_refresh_tokens` | No (looked up by hashed token) | 90-day rotation w/ `family_id` for reuse detection |

All three skip RLS — they're keyed by client_id or token-hash and looked up before user identity is established. Cleanup runs hourly via `Engram.Workers.CleanupDeviceAuthWorker`.

## Phase 7 — SPA consent mediation (all shipped)

Phases 7.A/7.B/7.C are all shipped; the live Connectors flow has been verified against Claude Desktop Connectors.

**Phase 7.A — SPA mediation:** `GET /oauth/authorize` is public. It validates client_id + redirect_uri + PKCE then 302s the browser to `/oauth/consent?<all-params-preserved>`. The React SPA reads the URL params, fetches `/api/oauth/clients/:client_id` to display the client name, renders a consent UI under the user's existing Clerk JWT session, and POSTs `/api/oauth/authorize/consent` with `vault_choice` + the full param set. The backend mints the code and returns JSON `{redirect_uri: "..."}` so the SPA does `window.location.assign(json.redirect_uri)`.

**Phase 7.B** ships the actual React consent page. **Phase 7.C** is the live Connectors walk-through against `mcp.engram.page` + `engram.ax`, plus cross-client conformance (Cursor / Continue / ChatGPT custom GPT). All complete.

## Failed approaches (none yet)

The plan TDD'd cleanly through Phases 0-6 without abandoned branches. Open question dispositions:
- **Token-family revocation in Phase 4 (vs deferring to Phase 6)** — included in Phase 4 (`family_id` column + revoke-on-replay). Catches the post-rotation replay attack the day token rotation ships.
- **Audience claim (`aud=https://app.engram.page/api/mcp`)** — deferred. Engram's `Engram.Token` Joken config has a single `aud=engram` validator that would need a list-aware rewrite. Worth doing when we have a second token type that needs distinguishing.
- **Remember-consent checkbox** — deferred to UX iteration.
