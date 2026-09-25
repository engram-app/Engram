# Context Doc: Official MCP Registry Publishing

_Last verified: 2026-09-25_

## Status
Live. `io.github.engram-app/engram` 0.32.0 published 2026-09-25 and active. Every
`release-v*` tag re-publishes automatically via `.github/workflows/publish-mcp-registry.yml`.
A version is immutable once published: a `title`/`description` change in `server.json` only
reaches the registry with the NEXT release tag (0.32.0 and 0.33.0 carry the pre-#1757 copy).

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
**GitHub OIDC from Actions**, in `.github/workflows/publish-mcp-registry.yml`
(`mcp-publisher login github-oidc`, job has `id-token: write`). A workflow in an
`engram-app` repo is granted `io.github.engram-app/*`.

A personal `mcp-publisher login github` does NOT work for the org namespace, even for an
org member with PUBLIC membership: it returned `403 ... You have permission to publish:
io.github.Rasbandit/*`. Most likely cause (unconfirmed): the org restricts third-party OAuth
apps, so the registry's OAuth app cannot see the membership. OIDC sidesteps it.

Chosen over DNS-namespace auth (`page.engram/...`), which would need a DNS TXT record plus an
ed25519 private key to store. With no `packages` block the registry's package-ownership
verification does not apply, so namespace auth is the only auth needed.

## Key Commands / Patterns

```bash
# normal path: merge release-please's release PR; the release-v* tag publishes.
# manual re-publish (only a NEW version is accepted):
gh workflow run publish-mcp-registry.yml --ref main -R engram-app/Engram

mcp-publisher validate server.json   # local check → "✅ server.json is valid"
curl "https://registry.modelcontextprotocol.io/v0/servers?search=engram-app"   # verify
```

The workflow pins `mcp-publisher` and checks its sha256 (the job holds a token that can
publish as us). Bump both `MCP_PUBLISHER_VERSION` and `MCP_PUBLISHER_SHA256` together, from
the release's `registry_<ver>_checksums.txt`.

## Failed Approaches / Dead Ends
- Personal `mcp-publisher login github` for the org namespace: 403, see Auth.
- DNS-namespace auth (`page.engram/...`) — rejected, needs a DNS TXT record and an ed25519
  private key kept somewhere. GitHub org auth needs neither.

## Gotchas
- **`version` is bumped by release-please**, via the `json` extra-file entry in
  `release-please-config.json` (`$.version`). It was hand-synced until 0.28.0 and drifted
  immediately — the 0.29.0 release PR did not touch it, so the manifest would have
  advertised a version two releases stale. The registry rejects re-publishing an existing
  version, so this only matters at publish time, but the drift is silent until then.
- The only `_meta` key the registry preserves is
  `io.modelcontextprotocol.registry/publisher-provided` (4KB limit). Every other `_meta` key
  is silently dropped.
- **Name collision:** 6+ servers named `engram` are listed, including
  `app.getengram/engram` titled "Engram" (same AI-memory category). Our `title` and
  `description` therefore carry the differentiator; the copy comes from the workspace
  `docs/context/messaging.md` (the messaging standard). Registry limits: `title` and
  `description` are 100 chars each (schema `maxLength`).
- The registry is still labeled "preview" upstream. Breaking changes or data resets are possible.

## References
- `server.json` (repo root)
- PR https://github.com/engram-app/Engram/pull/1695 (manifest), #1756 (OIDC publish workflow)
- `docs/context/mcp-oauth.md` — OAuth 2.1 + DCR on the MCP endpoint
