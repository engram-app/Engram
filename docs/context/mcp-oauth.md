# MCP OAuth 2.1 + DCR + CIMD: How It Works

_Last verified: 2026-10-16_

End-to-end OAuth 2.1 + Dynamic Client Registration on Engram's MCP endpoint, so Claude Connectors / Cursor / ChatGPT custom GPTs / any other standards-compliant client can auto-auth against `mcp.engram.page/api/mcp` (saas) or `engram.ax/api/mcp` (selfhost) without per-client integration code.

> **Host note:** the saas MCP endpoint is `mcp.engram.page`, NOT `app.engram.page` (the SPA). See workspace `../engram-workspace/docs/context/public-url-host-split.md`. All curl examples below use `mcp.engram.page`.

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
10. POST /oauth/revoke                           → 200 once the client authenticates (RFC 7009)
```

CIMD clients (Claude, ChatGPT) skip step 3: they send an HTTPS URL as `client_id`, and `/oauth/authorize` fetches that metadata document. See `cimd-vs-dcr-validation-policy.md`.

## Endpoint reference

| Method + path | Auth | Purpose |
|---------------|------|---------|
| `GET /.well-known/oauth-protected-resource` | none | RFC 9728 — points clients at `/api/mcp` + lists auth server |
| `GET /.well-known/oauth-authorization-server` | none | RFC 8414 — server metadata (endpoints, grant types, PKCE S256, scopes) |
| `POST /oauth/register` | none, rate-limited 60/IP/min | RFC 7591 DCR. Public (`none`) or confidential (`client_secret_post` / `client_secret_basic`, secret returned once); PKCE mandatory either way |
| `GET /oauth/authorize` | none, rate-limited 10/IP/min | Validates request, 302s to `/oauth/consent` (SPA mediation, Phase 7.A) |
| `GET /api/oauth/clients/:client_id` | none, rate-limited 10/IP/min | Public client metadata for the consent UI: `client_id`, `client_name`, `kind`, `slug`, plus `redirect_uri_registered` / `redirect_host` / `redirect_loopback` for the `redirect_uri` query param, and `client_host` (the host of a metadata-document client_id, shown as "App details from"). The page refuses an unregistered redirect and offers Cancel only for one the backend confirmed (fails closed, wizard Cancel too), shows the host (`scheme://host` for an app scheme), and warns on a localhost redirect |
| `POST /api/oauth/authorize/consent` | Bearer JWT | SPA submits w/ `vault_choice`. Mints code. JSON `{redirect_uri: "..."}` for SPA `window.location` |
| `POST /oauth/token` | client auth, rate-limited 300/min per {client_id, IP} plus 3,000/min per IP | RFC 6749 §3.2 — auth code → tokens, refresh → rotated tokens |
| `POST /oauth/revoke` | client auth, rate-limited 300/min per {client_id, IP} plus 3,000/min per IP | RFC 7009. Client auth is `EngramWeb.OAuthClientAuth`, shared with `/oauth/token` (body id, Basic, or assertion; an assertion's `aud` may be the revoke URL). Bad auth is 401 `invalid_client`, a missing `token` is 400 `invalid_request`, an access token is 400 `unsupported_token_type`; otherwise 200 whether or not the token existed |

## Token model

- **Audience binding (RFC 8707, #1977)** — **Staged: minting is OFF this release** (`:oauth_mcp_audience_tokens`, default false), so OAuth tokens still carry `aud: "engram"` and behave as before. Every node now verifies both audiences; the next release flips the default (then deletes the flag), because a node on the previous release 401s `engram:mcp` and a rolling deploy runs two releases behind the ALB. Before flipping, check prod for live refresh families whose `scope` lacks `mcp` (they would 403). Once on: OAuth access tokens carry `aud: "engram:mcp"` (`Engram.Token.mcp_audience/0`) and resolve only on routes declaring `private: %{token_surface: :mcp}`: `POST /api/mcp` and `POST /api/attachments` (the `get_attachment_upload_target` tool tells clients to upload there with the same token). Everywhere else, REST and the sync socket, they get 401 `invalid_token` via `TokenResolver.resolve/2`, checked before any verifier because on self-host the Local provider would accept them as sessions. A `resource` naming another host is `invalid_target` at authorize and token (after client auth there; host case-insensitive; empty is absent). Device-flow tokens keep `aud: "engram"`. The `mcp` scope is required on MCP-audience tokens (403 `insufficient_scope`).
- **Access token** — internal HS256 JWT minted by `Engram.Accounts.generate_jwt/2` with optional `scope` + `vault_id` claims. 15-min TTL. Stateless (no DB row, can't revoke mid-life — short TTL is the mitigation). `EngramWeb.Plugs.Auth` validates via `TokenResolver`'s third fallback path (already existed pre-OAuth for the device flow).
- **Refresh token**: `engram_oauth_rt_<...>` opaque random, sha256-hashed at rest. 90-day TTL. Stored in `oauth_refresh_tokens` with a `family_id` per RFC 6749 §10.4. Rotation on use; replay of a consumed token revokes the entire family, except inside the 60 s grace window below. The first family's id is the authorization code's id, so a replayed code (past the same 60 s, before the code's own 10-min expiry, and only after its client and PKCE checks pass) revokes everything it issued (RFC 6749 §4.1.2), refused as reason `code_replay_revoked`. The device and local-auth paths have their own leeway (see `refresh-token-reuse-detection.md`).

### Refresh grace window (#1974) and its tradeoff

A client whose rotation response is lost retries with the token it still holds. Before #1974 that revoked the family, so every lost response killed the connection. Now a replay of a consumed token **within 60 s**, while its successor has **never been used**, re-issues: the unused successor is revoked and one new successor is minted, so the family never has two live tokens. Every duplicate inside the window is handled the same way, up to **5 re-issues per token**; the window is anchored at the token's first use (`consumed_at`, set once), so replays cannot slide it. The 6th replay is reuse and revokes the family. The count is the successor rows the re-issue already locks, so no column is needed (Hydra caps the same way, `used_times < N`).

Every decision about a refresh token runs in one transaction holding `FOR UPDATE` on the presented row, so rotations of one token serialize and the second sees the first one's result. Every Disconnect path revokes through `Engram.OAuth.revoke_refresh_tokens/2`, which first locks the live rows (waiting for any rotation holding one) and then revokes with a fresh statement, so a successor a rotation just committed is revoked too. `Engram.OAuthRotationRaceTest` proves both on separate committing connections.

The cost: inside the window, whoever presents the consumed token first gets the new one. What bounds it:

- The replay must come from the **same `client_id`** (`:client_mismatch` otherwise), and a `private_key_jwt` or secret client must pass client authentication first (the token controller authenticates before `rotate_refresh_token/3` runs).
- Nothing minted since may have been **used**: a consumed successor means the client had it, so the replay is theft and the family is revoked.
- At least one successor must still be live: one revoked any other way (RFC 7009, Disconnect) is never resurrected by replaying its parent.
- A token found revoked under the lock is refused as `refresh_token_revoked`, not logged as reuse.
- The successors are locked and the revoke must hit every live one read; anything else is treated as reuse.
- If the successor the grace revoked turns up later, two parties held the lineage: the `revoked_at` clause revokes the family.
- Every re-issue logs `oauth_refresh_grace_reissue` with `client_id`, `family_id` and `ip_matched` (whether the replay came from the IP that received the successor). `ip_matched=false` is the line to read when looking for theft; it is not refused, because a vendor backend (ChatGPT, Claude) may retry from a different egress IP.

## Scope grammar

Three values minted at consent:
- `mcp` — required, identifies as MCP-server token (vs general-purpose internal JWT)
- `vault:<id>` — bound to one vault. Any tool call with a different `vault_id` arg is rejected by `EngramWeb.Plugs.OAuthScopeEnforce` + `McpController.resolve_mcp_vault/3`.
- `vault:*` — all user's vaults. Tool calls choose `vault_id` per-call.

Scope is propagated through code → refresh token → access JWT. Today the JWT carries `vault_id` as a separate claim (not parsed from the scope string): simpler enforcement, same effect.

### Vault resolution per tool call

MCP is stateless JSON-RPC, so the server keeps no active vault between calls. Every vault-scoped tool takes an optional `vault_id` (name or UUID). A bare call resolves to the credential's only reachable vault, or errors when it can reach several (`McpController.resolve_mcp_vault/3`). Never fall back silently to `is_default`: that flag exists for single-vault and onboarding convenience, and using it to disambiguate several vaults was #985.

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

Returns 200 per RFC 7009 §2.2 once the client authenticates, except an access token (400 `unsupported_token_type`, §2.2.1) or a missing/non-string `token` (400 `invalid_request`). If `client_id` doesn't own the token, it's a silent no-op (token survives — leaking the distinction would help an attacker enumerate live tokens). Revoking a token in a refresh family also burns the rest of the family if any consumed-or-revoked replay is later detected.

## Database schema

| Table | Tenanted? | Purpose |
|-------|-----------|---------|
| `oauth_clients` | No (shared, pre-login) | DCR-registered clients, PK `client_id` (UUID) |
| `oauth_authorization_codes` | No (looked up by hashed code, pre-token) | One-time codes, 10-min TTL, sha256-hashed |
| `oauth_refresh_tokens` | No (looked up by hashed token) | 90-day rotation w/ `family_id` for reuse detection |

All three skip RLS — they're keyed by client_id or token-hash and looked up before user identity is established. Cleanup runs hourly via `Engram.Workers.CleanupDeviceAuthWorker`.

## Spec conformance notes (#1977)

Audited against MCP 2025-11-25 authorization, OAuth 2.1, RFC 8414/9728/7591/7636/8707/9207/7009/6750/7523 and the CIMD draft. Deliberate deviations, each kept because tightening it breaks a named client:

- ChatGPT declares `private_key_jwt` but exchanges as a public client; accepted because its document lists `none` as permitted.
- Custom-scheme redirects (`cursor://`) are admitted; MCP wants https or localhost, Cursor desktop needs this.
- The loopback any-port rule also covers the `localhost` hostname (RFC 8252 prefers IP literals); Claude Code registers `localhost`.
- The root `/.well-known/oauth-protected-resource` on app/api/self-host hosts advertises `.../api/mcp` rather than the root; clients that fall back to it compare it to the URL they dialed.
- No DPoP/mTLS sender-constrained tokens: no MCP client sends them.
- Audience binding (RFC 8707, MCP "Token Handling") is staged: OAuth tokens still mint `aud: "engram"` this release, so the `mcp`-scope check on MCP-audience tokens is not live yet either. See Token model.
- `/api/mcp` accepts more than OAuth tokens: API keys (Free and paid users connect with them), Clerk sessions and device tokens. MCP says the server MUST NOT accept tokens not issued for it; one direction holds (an MCP token reaches nothing else), the other is kept for API-key users.
- A replayed code past its 10-min expiry revokes nothing: a callback page reloaded later is not an attack.
- `iss` (RFC 9207) is **staged off** (`OAuthMetadata.iss_enabled?/0`, `:oauth_iss_response`). It is emitted (success, error and both Cancel paths) and advertised together or not at all: §2.4 says a client SHOULD discard an unadvertised `iss` and MUST reject a missing one once advertised. The SPA already forwards it; flip the flag once that SPA is promoted, then delete it.
- A token request that omits `redirect_uri` is accepted (OAuth 2.1 §4.1.3 / §10.2: 2.1 clients do not send it); present, it must match. RFC 6749 §4.1.3 required it when authorize named it; PKCE binds the code instead.
- A replayed code inside the 60 s grace window revokes nothing (§4.1.2 says SHOULD revoke): a client retrying its own in-flight exchange must not lose the grant it just got.
- Repeated `resource=` keys: Plug keeps the last one, so `resource=evil&resource=ours` validates on `ours` (RFC 8707 wants `invalid_target`). The `resource[]=` list form is checked in full.
- A CIMD document served `no-cache`/`no-store` is cached 5 min anyway (the TTL floor), so a hot client does not fetch per authorize.
- `/oauth/revoke` answers `unsupported_token_type` for any valid access JWT, not just the caller's: the JWT carries no client claim, and the holder of a token can test it by using it anyway.

Vendor flows: `test/support/oauth_flow.ex` + `test/engram_web/oauth_vendor_flow_test.exs` replay 14 real client shapes from prod `oauth_clients` rows end to end. Add a vendor there when one first connects; never guess a fixture.

