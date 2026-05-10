# MCP OAuth Phase 7 — SPA Mediation for `/oauth/authorize`

## Context

PRs #91-#99 shipped the OAuth 2.1 + DCR server (Phases 0-6 + 10 + redaction prep). Prod is at `0.5.57` on `app.engram.page` with verified discovery + DCR + token endpoints. **The first real Connectors UI test failed at `/oauth/authorize`:**

```
Claude desktop → Settings → Add Connector → https://app.engram.page/api/mcp
1. Discovery (.well-known) — OK
2. DCR (POST /oauth/register) — OK, registered client_id=eb081ac3-1eac-49d7-ad35-adb2e924f74a
3. Browser redirect to GET /oauth/authorize?... — 401 {"error":"unauthorized"}
```

Observed `/oauth/authorize` query string (preserve all of these in the redirect to SPA):

```
response_type=code
client_id=eb081ac3-1eac-49d7-ad35-adb2e924f74a
redirect_uri=https://claude.ai/api/mcp/auth_callback
code_challenge=qJmmGpR1KmuXxpgvF6zErmRnbfQLIOwVzT5h013wVDg
code_challenge_method=S256
state=M5Y1kQg-7aYxnl3qIE3Y70RHnUZ4ShU784xKpu5Q0cM
scope=mcp
resource=https://app.engram.page/api/mcp        # RFC 8707 resource indicator — pass-through, no validation yet
```

**Why it failed:** `/oauth/authorize` is a *user-agent endpoint* per RFC 6749 §4.1.1 — the browser hits it via 302 from Claude. Browsers don't carry `Authorization: Bearer ...` on navigations; they carry cookies. Phase 3's controller required Bearer (works in tests, breaks in real browsers). Plan + PR explicitly deferred this to Phase 7.

**Goal:** Make `/oauth/authorize` work end-to-end for the Connectors flow without building first-party session cookies (Engram has none today). Use **SPA mediation** — backend redirects to React, SPA uses its existing Clerk session.

## Educational Primer (skip if you already know)

Three honest architectures for this problem:

| Option | Pro | Con |
|--------|-----|-----|
| 1. SPA mediation | Zero new auth infra; reuses Clerk JWT in localStorage; consent UI in React | Depends on SPA + Clerk being healthy |
| 2. First-party session cookie | Classical OAuth server design; SPA-independent | Engram has zero `Plug.Session` infra today — would need cookie secret rotation, secure/httponly, CSRF, login flow rework on saas + selfhost |
| 3. Clerk-as-IdP | Leverage Clerk's auth UI | Adds Clerk pricing/dependency to every grant; doesn't work for selfhost; less control over consent UX |

**This plan ships Option 1.** Smallest surface that fits Engram's existing architecture.

## Architecture

### Wire flow after Phase 7

```
Claude → GET /oauth/authorize?... on backend (PUBLIC, no auth)
       → controller validates client_id + redirect_uri + response_type + PKCE + scope
       → if invalid client/redirect → 400 HTML (existing behavior)
       → if invalid params → 302 to redirect_uri?error=... (existing behavior)
       → if valid → 302 to /app/oauth/authorize?<all-params-preserved>
       
Browser → loads SPA at /app/oauth/authorize
        → SPA reads URL params
        → if not Clerk-authenticated → redirect to /app/sign-in?return_to=<this-url>
        → if authenticated → fetch /api/vaults (Bearer Clerk JWT)
        → render React consent page: "Authorize Claude to access your Engram"
                                     [ ] vault: Personal
                                     [ ] vault: Work
                                     [x] All vaults
                                     [ Approve ]   [ Cancel ]
        → on Approve: POST /api/oauth/authorize/consent
                      headers: Authorization: Bearer <clerk-jwt>
                      body: {client_id, redirect_uri, code_challenge, code_challenge_method, state, scope, vault_choice, resource}
        → backend re-validates request, mints code, returns {redirect_uri: "https://claude.ai/api/mcp/auth_callback?code=...&state=..."}
        → SPA: window.location.assign(response.redirect_uri)
        → on Cancel: window.location.assign(redirect_uri + "?error=access_denied&state=" + state)

Browser → arrives at Claude's redirect_uri with ?code=...&state=...
Claude → POST /oauth/token with code + PKCE verifier (Phase 4 — already works)
```

### Backend changes (TDD-ordered)

| File | Change |
|------|--------|
| `lib/engram_web/router.ex` | Move `GET /oauth/authorize` out of the `[:api, EngramWeb.Plugs.Auth]` pipeline into a public scope. Add `POST /api/oauth/authorize/consent` under the existing user-scoped auth pipeline (`[:api, Auth, RotationLockCheck]`). Retire `POST /oauth/authorize`. |
| `lib/engram_web/controllers/oauth_authorize_controller.ex` | `show/2` no longer renders consent — instead, after validation, 302 to `/app/oauth/authorize?<params>` (preserve every input param incl. `resource`). Drop the inline HTML consent rendering. New `consent/2` action: requires `conn.assigns.current_user`, body has the full param set + `vault_choice`, mints code via existing `OAuth.mint_authorization_code/3`, returns `{redirect_uri: "..."}` JSON. Drop `submit/2`. |
| `lib/engram/oauth.ex` | No public-API change. `mint_authorization_code/3` already returns `{:ok, redirect_url}` — that's what the controller serializes as JSON. |
| `test/engram_web/controllers/oauth_authorize_controller_test.exs` | Rewrite: GET tests assert 302 to `/app/oauth/authorize?...` (with all params preserved); 400 HTML cases unchanged; redirect-error cases unchanged. New POST tests for `/api/oauth/authorize/consent`: happy path + vault ownership + `vault:*` + 401 without auth + invalid params returns redirect URL with `error=`. |

### SPA changes (`backend/frontend/`)

| File | Change |
|------|--------|
| `src/routes.tsx` (or wherever routes live) | New route `/app/oauth/authorize` → new `OAuthAuthorize` page component. Keep it inside the auth-required layout so unauth'd users get bounced to `/app/sign-in?return_to=...`. |
| `src/pages/OAuthAuthorize.tsx` | New component. Reads URL params via `useSearchParams`. Fetches `/api/vaults` (existing endpoint, Bearer-auth via existing client). Renders consent UI: client_name (need backend to surface — see Open Question 1), vault picker (radio buttons + "All vaults" default checked), Approve/Cancel buttons. On Approve: POST `/api/oauth/authorize/consent` with full param set + vault_choice. On 200: `window.location.assign(json.redirect_uri)`. On error: render inline error. On Cancel: `window.location.assign(redirect_uri_with_error)`. |
| `src/api/oauth.ts` (new) | Tiny client wrapper: `consent(params, vaultChoice) → Promise<{redirect_uri: string}>`. |

### Selfhost compatibility

The SPA is the same React build for both saas and selfhost. Selfhost uses local auth (not Clerk) — the existing `useUser`/auth hook in the SPA already handles both. No fork needed. The consent page just needs to surface `current_user.email` agnostically of provider, which the existing `/api/me` endpoint already does.

## Phases (one PR each, TDD-ordered)

### Phase 7.A — Backend route split + redirect (~1 hr, PR #1)

1. **TDD:** rewrite `oauth_authorize_controller_test.exs` GET tests to assert 302 to `/app/oauth/authorize?<params>`. Run → red.
2. Move `GET /oauth/authorize` out of the `:api + Auth` pipeline into a public scope (still goes through `:api` for content-negotiation, just no `Auth` plug).
3. Update controller `show/2`: skip the consent-rendering branch, always 302 to SPA on validated input.
4. Run tests → green.
5. Add new `POST /api/oauth/authorize/consent` route in the existing user-scoped pipeline (`[:api, EngramWeb.Plugs.Auth, EngramWeb.Plugs.RotationLockCheck]`).
6. **TDD:** new tests for `consent/2`: 401 without auth (Auth plug), validated request + vault_choice → JSON `{redirect_uri: "..."}` with `code` and `state` query params, vault_ownership rejected → JSON `{redirect_uri: "...?error=access_denied..."}`.
7. Implement `consent/2` (very similar to today's `submit/2`, but returns JSON not 302).
8. Drop `submit/2` + the old `POST /oauth/authorize` route.
9. Bump `mix.exs`, push, open PR.

**Note on backward-incompat:** dropping `POST /oauth/authorize` breaks the smoke-curl pattern in `docs/context/mcp-oauth.md`. Update that doc's "How to add a client manually" to use the SPA flow OR document curl-only as `POST /api/oauth/authorize/consent`.

### Phase 7.B — SPA route + consent UI (~1 hr, PR #2)

1. New route `/app/oauth/authorize` in the React Router config (under the auth-required layout).
2. New `OAuthAuthorize.tsx` component:
   - `useSearchParams()` for incoming params
   - `useVaults()` (existing hook, or fetch `/api/vaults`)
   - Radio buttons: each vault + "All vaults" (default selected)
   - Approve button → POST `/api/oauth/authorize/consent` → `window.location.assign(json.redirect_uri)`
   - Cancel button → constructs `redirect_uri` + `?error=access_denied&state=...` + assigns
3. Style with existing Tailwind classes (consistent with rest of SPA — use the same modal/card chrome as e.g. the API key creation flow).
4. Manual smoke test in dev: fake the params, verify the round-trip works against local backend.
5. Plugin/E2E tests not required (this is SPA-only); rely on the live walk in 7.C.

### Phase 7.C — Live Connectors walk + capture (~30 min, no PR)

After 7.A + 7.B deploy to prod:

1. Claude desktop → Settings → Connectors → Add → `https://app.engram.page/api/mcp`.
2. Walk the flow. Expected:
   - Discovery hits land
   - DCR mints client
   - Browser redirects to `/oauth/authorize?...` → backend 302s to `/app/oauth/authorize?...`
   - SPA loads consent page, shows vault picker
   - Approve → `window.location` to `https://claude.ai/api/mcp/auth_callback?code=...&state=...`
   - Claude POSTs `/oauth/token` → access + refresh issued
   - First MCP tool call lands with the access token, MCP scope-enforce honors `vault_id` claim
3. Capture the wire trace via Phoenix request logger (RedactFilter from PR #99 already scrubs PKCE + tokens).
4. File any spec-divergence as Phase 7.D PRs.

## Open questions

1. **Surface `client_name` to the SPA.** Today's GET `/oauth/authorize` validation returns the Client struct internally; the SPA needs the human-readable name to render *"Authorize **Claude** to access..."*. Two options:
   - Pass `client_name` as an extra query param in the GET → SPA redirect (URL-encoded). Simple but exposes the name in the URL bar.
   - SPA fetches `/api/oauth/clients/:client_id` (new public endpoint returning only `client_name`). Cleaner. Add a tiny rate limit.
   
   **Lean:** the second option (new endpoint), since it also lets the SPA show client metadata without a backend round-trip if cached.

2. **`resource` parameter (RFC 8707).** Claude sends `resource=https://app.engram.page/api/mcp`. Today we ignore it. Should we:
   - Validate it matches the canonical `Endpoint.url() <> "/api/mcp"` and reject mismatch? RFC 8707 says "MAY".
   - Pass-through only? Safer for now — defer to Phase 7.D if Connectors enforces matching.
   
   **Lean:** pass-through. If we validate now and Claude ever sends a slightly different host (port, trailing slash), we 400 and break the flow.

3. **Cancel UX.** When user clicks Cancel, do we:
   - Redirect back to Claude with `?error=access_denied&state=...` (RFC-compliant)?
   - Stay on the SPA and let the user navigate away (Connectors would just timeout)?
   
   **Lean:** RFC-compliant redirect. Claude shows a "user cancelled" message gracefully.

4. **Selfhost auth on `/app/oauth/authorize`.** Selfhost SPA already routes unauth'd users to `/app/sign-in`. Verify that `return_to=/app/oauth/authorize?<params>` works for the local-auth login form (probably already does — `useReturnTo` hook should handle it). If not, fix that bug as part of 7.B.

5. **Should we DELETE `lib/engram_web/controllers/oauth_authorize_controller.ex`'s consent template HTML?** Yes — it's dead code after 7.A. Removing keeps `mix credo` clean.

## Critical files to read before each phase

- 7.A: `lib/engram_web/router.ex` (current OAuth scopes), `lib/engram_web/controllers/oauth_authorize_controller.ex` (full current file), `lib/engram/oauth.ex` (`validate_authorization_request/1`, `mint_authorization_code/3`)
- 7.B: `backend/frontend/src/routes.tsx` (or equivalent), `backend/frontend/src/components/auth/` for the existing Clerk-protected layout pattern, `backend/frontend/src/hooks/` for `useVaults` / fetch wrappers, the existing API key creation flow as a UI reference
- 7.C: `docs/context/mcp-oauth.md` (curl smoke for the live test)

## Verification

### Per-phase
- 7.A: `mix test` green; smoke `curl -i https://localhost:4000/oauth/authorize?...` returns 302 to `/app/oauth/authorize?...`; `curl -X POST -H "Authorization: Bearer <jwt>" .../api/oauth/authorize/consent` mints code
- 7.B: SPA dev server (`bun run dev` in `frontend/`) renders consent page when given fake URL params; vault picker shows real vaults from `/api/vaults`; approve POSTs and redirects

### End-to-end (after 7.A + 7.B deploy)
- Real Claude desktop Connector flow returns access token, first tool call (`list_notes`) succeeds, returns notes from chosen vault
- Mismatched vault_id in tool args → 403 (Phase 5 enforcement still working)

### Spec compliance probes
Update `backend/scripts/oauth-smoke.sh` (or create) with:
```bash
# Discovery (already works)
curl https://app.engram.page/.well-known/oauth-protected-resource | jq .

# DCR (already works)
curl -X POST https://app.engram.page/oauth/register \
  -H "Content-Type: application/json" \
  -d '{"redirect_uris":["http://localhost:9999/cb"],"client_name":"smoke"}'

# Authorize redirect (Phase 7.A)
curl -i "https://app.engram.page/oauth/authorize?response_type=code&client_id=<dcr-id>&redirect_uri=http://localhost:9999/cb&code_challenge=abc&code_challenge_method=S256&state=xyz&scope=mcp"
# expect: HTTP/2 302  Location: /app/oauth/authorize?...

# Consent (Phase 7.A, with real Bearer)
curl -X POST https://app.engram.page/api/oauth/authorize/consent \
  -H "Authorization: Bearer $JWT" \
  -H "Content-Type: application/json" \
  -d '{"client_id":"<dcr-id>","redirect_uri":"http://localhost:9999/cb","code_challenge":"abc","code_challenge_method":"S256","state":"xyz","scope":"mcp","vault_choice":"vault:*"}'
# expect: 200 {"redirect_uri":"http://localhost:9999/cb?code=...&state=xyz"}
```

## Cross-references

- Original plan: `docs/superpowers/plans/2026-05-09-mcp-oauth-dcr.md` (this is its Phase 7)
- Live wire flow: `docs/context/mcp-oauth.md`
- Memory: `~/.claude/projects/-home-open-claw-documents-code-projects-engram-workspace/memory/project_mcp_oauth.md`
- Failed first attempt observed: 2026-05-10 02:00 UTC, Claude desktop Connectors UI, redirect URL captured in spec Context section
