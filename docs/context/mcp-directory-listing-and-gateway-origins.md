# Context Doc: MCP directory listings and gateway Origins

_Last verified: 2026-10-08_

## Status
Fix pending deploy (branch `feat/mcp-server-card`, commit 909399f5). The exact Origin Smithery sends is inferred, not observed.

## What This Is
Why third-party MCP directories (Smithery, MCPRush) fail to scan or proxy `https://mcp.engram.page`, and the SEP-1649 server card we serve for them.

## Environment
SaaS prod, `mcp.engram.page` (Cloudflare in front, ECS behind). Applies to any directory whose scanner/gateway sends an `Origin` header.

## Connection
- MCP endpoint: `POST https://mcp.engram.page` (host-rewritten to `/api/mcp`)
- Server card: `GET /.well-known/mcp/server-card.json` (`WellKnownController.mcp_server_card`)

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
- **Cloudflare Bot Fight Mode.** Smithery's error ("Initialization failed with status 403") suggests it. It is OFF (`fight_mode:false`, see engram-infra `docs/context/cloudflare-settings-not-in-terraform.md`). The 403 is ours, from the Origin guard.
- **Server card alone.** Does not fix Smithery: every user call goes through Smithery's Cloudflare Workers gateway with the same Origin, so the guard change is required for real use, not just the scan.
- **MCPRush "New server".** That is a paid resale gateway. Use the direct-connection free listing instead.

## Gotchas
- If the Smithery scan still 403s after deploy, the guard emits only telemetry `[:engram, :abuse, :mcp_origin_rejected]` with NO origin value. Temporarily log the rejected Origin to learn the real one, then add it.
- SEP-1649 (server card) is still a proposal, not in the MCP spec. Smithery and MCPRush consume it; Claude, ChatGPT and the official registry do not.
- The engram-infra Cloudflare Cache Rule was NOT extended to the card path, so it serves `cf-cache-status: DYNAMIC`. Harmless.
- MCPRush unpublish cannot be undone from the studio; support@mcprush.com was emailed (2026-10-08).

## References
- Official MCP Registry: `io.github.engram-app/engram` (`server.json`, see `mcp-registry-publishing.md`)
- Smithery listing: `engram/memory` under the `engram` team namespace
- `lib/engram_web/plugs/mcp_origin_guard.ex`, `lib/engram_web/plugs/host_rewrite.ex`, `lib/engram_web/plugs/cors.ex`
