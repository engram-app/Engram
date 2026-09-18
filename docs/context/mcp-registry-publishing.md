# Context Doc: Official MCP Registry Publishing

_Last verified: 2026-09-17_

## Status
Working — `server.json` validates; not yet published.

## What This Is
How Engram gets listed in the official MCP registry at `registry.modelcontextprotocol.io`,
via the repo-root `server.json` and the `mcp-publisher` CLI.

## Connection
- Registry API: `https://registry.modelcontextprotocol.io`
- Registry name: `io.github.engram-app/engram`
- Manifest: `server.json` at the repo root

Remote-only entry, no `packages` block:

```json
"remotes": [{ "type": "streamable-http", "url": "https://mcp.engram.page" }]
```

The bare host is correct, no path. Verified: `POST https://mcp.engram.page` returns 401
(live, auth-gated), and `GET https://mcp.engram.page/.well-known/oauth-protected-resource/api/mcp`
returns `resource: https://mcp.engram.page` (bare), so bare is already the canonical form in
shipped metadata. `POST /api/mcp` also 401s and `GET /api/mcp` returns 405.

## Auth
Namespace auth is GitHub device flow, run by an `engram-app` org member:

```bash
mcp-publisher login github
```

Chosen over DNS-namespace auth (`page.engram/...`), which would need a DNS TXT record plus an
ed25519 private key to store. With no `packages` block the registry's package-ownership
verification does not apply, so namespace auth is the only auth needed.

## Key Commands / Patterns

```bash
# install (this box: ~/.local/bin)
curl -L "https://github.com/modelcontextprotocol/registry/releases/latest/download/mcp-publisher_linux_amd64.tar.gz" | tar xz mcp-publisher

mcp-publisher validate            # → "✅ server.json is valid"
mcp-publisher login github
mcp-publisher publish

curl "https://registry.modelcontextprotocol.io/v0.1/servers?search=engram"   # verify
```

## Failed Approaches / Dead Ends
- DNS-namespace auth (`page.engram/...`) — rejected, needs a DNS TXT record and an ed25519
  private key kept somewhere. GitHub org auth needs neither.

## Gotchas
- **`version` is hand-synced to `mix.exs`** (currently 0.28.0). The registry rejects
  re-publishing an existing version, so bump it before every re-publish. No CI automation
  is wired for this.
- The only `_meta` key the registry preserves is
  `io.modelcontextprotocol.registry/publisher-provided` (4KB limit). Every other `_meta` key
  is silently dropped.
- **Name collision:** three servers named `engram` are already listed, including
  `app.getengram/engram` titled "Engram" (published 2026-09-08, same AI-memory category) and
  `ai.onedroid/engram`. Ours also titles itself "Engram".
- The registry is still labeled "preview" upstream. Breaking changes or data resets are possible.

## References
- `server.json` (repo root)
- PR https://github.com/engram-app/Engram/pull/1695
- `docs/context/mcp-oauth.md` — OAuth 2.1 + DCR on the MCP endpoint
