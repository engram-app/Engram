Title: Connections client identity — why `software_id` failed, redirect-host matching, the HTTPS trust model

_Last verified: 2026-06-15 (discovered fixing Claude identity on `/settings/connections` + onboarding checklist)_

How `/settings/connections` cards and the onboarding checklist identify an OAuth/MCP client (logo, display_name, verified badge, checklist auto-check).

## The gotcha: `software_id` is almost never sent

`Engram.Connections.LogoAllowlist` originally keyed identity on the RFC 7591 `software_id`. That field is **optional and most MCP clients omit it**. Verified live against claude.ai's remote-MCP connector:

- `software_id: null`, `client_name: "Claude"`
- redirect `https://claude.ai/api/mcp/auth_callback`, UA `python-httpx`

So `lookup(nil)` never matched → generic `<Plug>` icon, "unverified" badge, no Claude mark, no checklist auto-check.

## The fix: `LogoAllowlist.resolve/2`

Identity now resolves via `LogoAllowlist.resolve(software_id, redirect_uris)` in `lib/engram/connections/logo_allowlist.ex`:

1. Try the `software_id` allowlist first (preserves our own `engram-vault-sync` plugin).
2. Fall back to matching the **redirect_uri host** against a vendor-host allowlist (`claude.ai` → Claude).

A `slug` field now flows: `Connections.list_for_user/1` → `ConnectionsController.serialize/1` → `/api/connections` JSON → React checklist (`connectedSlugs.has(slug)` auto-checks the row).

## Trust model (security-relevant — do not weaken)

`verified: true` is granted **only** for a vendor-owned **HTTPS** host, no userinfo, case-folded.

- **Why HTTPS host is un-spoofable:** a forged DCR client can *claim* `redirect_uri=https://claude.ai/...`, but the auth code is then delivered to claude.ai — not to the attacker. The vendor controls the callback handler.
- **Why custom schemes / http are NOT:** `com.evil.app://claude.ai/cb` and `http://claude.ai/...` both parse to host `claude.ai` but deliver the code to an attacker-controlled handler. `lookup_by_host/1` enforces `%URI{scheme: "https", userinfo: nil}`. (Code review caught this — the naive host-only match was exploitable.)
- Custom schemes (`cursor://`) and `localhost` are **identify-only**: they may set icon/name but never grant `verified`.

## Known stale — the 4 guessed `software_id` entries

`anthropic-claude-desktop`, `cursor.sh`, `openai-chatgpt`, `vscode-engram` are UNVALIDATED guesses. Left in place because they're harmless — real clients don't send those IDs, so they never match. The only proven-real `software_id` is our own `engram-vault-sync`.

Real vendor callbacks (observed / published):

| Client | Redirect | Identity path |
|--------|----------|---------------|
| Claude | `https://claude.ai/api/mcp/auth_callback` | HTTPS host → verified |
| ChatGPT | `https://chatgpt.com/connector_platform_oauth_redirect` | HTTPS host → verified |
| Cursor | `cursor://` (native scheme) | identify-only |
| VS Code | `vscode://` (native scheme) | identify-only |

**To add a new client:** confirm its real redirect host by inspecting an actual `oauth_clients` row (below), then add an `@redirect_host` entry (HTTPS vendor host) — or an `@software_id` entry only if it genuinely sends one.

## Where to verify what a client actually sends

Ground truth is the DB, not published docs (which only give canonical values):

```sql
SELECT software_id, client_name, redirect_uris FROM oauth_clients;
```
