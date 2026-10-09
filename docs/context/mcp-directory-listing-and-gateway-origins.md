# Context Doc: MCP directory listings and gateway Origins

_Last verified: 2026-10-08_

## Status
LIVE. Smithery lists Engram as `engram/Engram-Memory` (scan passed 2026-10-08). The Smithery 403 was the Cloudflare empty-UA rule (engram-infra#1382), not the Origin guard. The exact Origin Smithery's gateway sends is still inferred, not observed.

## What This Is
Why third-party MCP directories (Smithery, MCPRush) fail to scan or proxy `https://mcp.engram.page`, and the SEP-1649 server card we serve for them.

## Environment
SaaS prod, `mcp.engram.page` (Cloudflare in front, ECS behind). Applies to any directory whose scanner/gateway sends an `Origin` header.

## Connection
- MCP endpoint: `POST https://mcp.engram.page` (host-rewritten to `/api/mcp`)
- Server card: `GET /server-card` on the MCP host (`/api/mcp/server-card` elsewhere) and `GET /.well-known/mcp/server-card.json` (`WellKnownController.mcp_server_card`)
- AI catalog: `GET /.well-known/ai-catalog.json`

## Auth
OAuth 2.1 (see `mcp-oauth.md`). A request with no token and an allowed (or absent) Origin gets 401 + the OAuth challenge. That 401 is the correct, healthy answer for a scanner.

## Key Commands / Patterns
```bash
# Guard rejects the Origin -> 403 (the Smithery symptom)
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Origin: https://smithery.ai' https://mcp.engram.page
# No Origin -> 401 (correct OAuth challenge)
curl -s -o /dev/null -w '%{http_code}\n' -X POST https://mcp.engram.page
```
- `EngramWeb.Plugs.McpOriginGuard` 403s any Origin not in `:cors_origin`. The fix adds a per-deployment `:mcp_gateway_origins` list, read from the `MCP_GATEWAY_ORIGINS` env var (comma-separated; exact origins or `https://*.domain` subdomain wildcards). Empty by default. Kept separate from `:cors_origin` because that list also opens REST CORS and the WebSocket origin check. Prod sets it in `engram-infra/main/envs/prod/ecs.tf` next to `ENGRAM_SAAS_FRONTEND_ORIGINS`; Smithery needs `https://smithery.ai,https://*.run.tools` (inferred, not observed).
- Server card is built from `Engram.MCP.Tools.wire_list/0`, so it cannot drift from the real tool list.
- On `mcp.engram.page` the card path must be listed in `HostRewrite` `@mcp_wellknown_prefixes`, or it 404s. It is pinned in `Plugs.CORS` `@cacheable_exact`.

## Failed Approaches / Dead Ends
- **Blaming the Origin guard for Smithery's scan 403.** Wrong. Cloudflare security events (filter Host = mcp.engram.page) showed the scan request (`POST /`, AS13335 Cloudflare Workers) arriving with an EMPTY User-Agent and hitting our own "Challenge empty / scanner-UA requests" custom rule. Smithery's docs claim `SmitheryBot/1.0`; the scanner sends none. Fixed by exempting `mcp.engram.page` from the empty-UA clause (engram-infra#1382). The gateway-origin allowlist is still needed for real proxied calls.
- **Cloudflare Bot Fight Mode.** Smithery's error text suggests it. It is OFF (`fight_mode:false`, see engram-infra `docs/context/cloudflare-settings-not-in-terraform.md`).
- **Server card alone.** Does not fix Smithery: every user call goes through Smithery's Cloudflare Workers gateway with the same Origin, so the guard change is required for real use, not just the scan.
- **MCPRush "New server".** That is a paid resale gateway. Use the direct-connection free listing instead.

## Gotchas
- If the Smithery scan still 403s after deploy, the guard emits only telemetry `[:engram, :abuse, :mcp_origin_rejected]` with NO origin value. Temporarily log the rejected Origin to learn the real one, then add it.
- The card follows `modelcontextprotocol/experimental-ext-server-card` v1 (still a draft, not in the MCP spec) AND keeps the SEP-1649 keys Smithery/MCPRush read. `McpServerCardTest` validates it against the vendored upstream schema. The card `name` must equal `server.json` `name` (test-enforced).
- To diagnose a directory's 403, read Cloudflare Security Events for `mcp.engram.page` FIRST: the WAF's managed challenge and the Origin guard both answer 403, and only the edge log tells them apart.
- The engram-infra Cloudflare Cache Rule was NOT extended to the card path, so it serves `cf-cache-status: DYNAMIC`. Harmless.
- MCPRush unpublish cannot be undone from the studio; support@mcprush.com was emailed (2026-10-08).

## References
- Official MCP Registry: `io.github.engram-app/engram` (`server.json`, see `mcp-registry-publishing.md`)
- Smithery listing: `engram/Engram-Memory` under the `engram` team namespace
- Glama: claimed via DNS (`_glama-claim.mcp.engram.page`, engram-infra `records.tf`)
- `lib/engram_web/plugs/mcp_origin_guard.ex`, `lib/engram_web/plugs/host_rewrite.ex`, `lib/engram_web/plugs/cors.ex`
