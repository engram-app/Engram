# MCP OAuth 2.1 + DCR — How It Works

End-to-end OAuth 2.1 + Dynamic Client Registration on Engram's MCP endpoint, so Claude Connectors / Cursor / ChatGPT custom GPTs / any other standards-compliant client can auto-auth against `app.engram.page/api/mcp` (saas) or `engram.ax/api/mcp` (selfhost) without per-client integration code.

Plan: `docs/superpowers/plans/2026-05-09-mcp-oauth-dcr.md`. Shipped in PRs #91-#97 across 6 backend phases (Phase 0-6) plus the docs PR.

## Wire flow (what Claude Connectors actually does)

```
1. GET  /.well-known/oauth-protected-resource    → {resource, authorization_servers}
2. GET  /.well-known/oauth-authorization-server  → endpoints + grant_types + PKCE
3. POST /oauth/register                          → mints client_id (DCR)
4. GET  /oauth/authorize?client_id&redirect_uri  → consent UI (vault picker)
5. POST /oauth/authorize {vault_choice}          → 302 redirect_uri?code&state
6. POST /oauth/token grant=authorization_code    → access_token + refresh_token
7. POST /api/mcp Authorization: Bearer ...       → tool calls (vault-locked)
8. POST /oauth/token grant=refresh_token         → rotated tokens (RFC 6749 §10.4 family)
9. POST /oauth/revoke                            → 200 always (RFC 7009)
```

## Endpoint reference

| Method + path | Auth | Purpose |
|---------------|------|---------|
| `GET /.well-known/oauth-protected-resource` | none | RFC 9728 — points clients at `/api/mcp` + lists auth server |
| `GET /.well-known/oauth-authorization-server` | none | RFC 8414 — server metadata (endpoints, grant types, PKCE S256, scopes) |
| `POST /oauth/register` | none, rate-limited 10/IP/min | RFC 7591 DCR — public PKCE clients only (no `client_secret`) |
| `GET /oauth/authorize` | Bearer JWT | Validates request, server-renders consent w/ vault picker |
| `POST /oauth/authorize` | Bearer JWT | Mints code, 302s redirect_uri+code+state |
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
curl -X POST https://app.engram.page/oauth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:9999/cb"],"client_name":"my-cli"}'

# Returns {"client_id":"<uuid>","client_id_issued_at":..., ...}
```

Use the returned `client_id` in a normal authorize → token flow. PKCE is mandatory.

## How to revoke a refresh token

```bash
curl -X POST https://app.engram.page/oauth/revoke \
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

## Phase 7+ — what's left

Phases 7-9 of the plan are smoke/conformance tests against:
- Real Claude desktop Connectors UI (`app.engram.page` + `engram.ax`)
- Cursor / Continue / ChatGPT custom GPT (cross-client conformance)

These need a live deployment after the PRs land. UX gap: today both `/oauth/authorize` verbs require a Bearer JWT (works in tests, doesn't work for a real browser without the SPA mediating). Phase 7 is when we wire the SPA path or a real cookie session.

## Failed approaches (none yet)

The plan TDD'd cleanly through Phases 0-6 without abandoned branches. Open question dispositions:
- **Token-family revocation in Phase 4 (vs deferring to Phase 6)** — included in Phase 4 (`family_id` column + revoke-on-replay). Catches the post-rotation replay attack the day token rotation ships.
- **Audience claim (`aud=https://app.engram.page/api/mcp`)** — deferred. Engram's `Engram.Token` Joken config has a single `aud=engram` validator that would need a list-aware rewrite. Worth doing when we have a second token type that needs distinguishing.
- **Remember-consent checkbox** — deferred to UX iteration.
