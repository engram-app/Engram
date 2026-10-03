# Product activity analytics — who is using Engram, and how

_Last verified: 2026-10-03. Shipped in v0.39.0 (#1813). Dashboards: Grafana `engram-usage`, plus the DAU/MAU/Activated tiles on `engram-business`._

Read this before touching `Engram.Observability.PostHog`, adding an event, or
trusting a "daily active users" number. For the **client-side** (posthog-js)
traps, see `posthog-instrumentation-traps.md`.

## What is emitted (server-side, `lib/engram/observability/posthog.ex`)

| Event | When | Throttle | Props |
|---|---|---|---|
| `surface_active` | web request (Clerk session), pushed Obsidian edit, any MCP call or handshake | 1 per person per surface per 5 min | `surface` (`web` `obsidian_sync` `mcp`), plus `plugin_version` and `client_type` on `obsidian_sync` |
| `mcp_tool_called` | MCP tool call (also argument-rejected ones) | 1 per person per tool per min | `tool` (allowlist, else `unknown`), `status` |
| `mcp_client_connected` | MCP `initialize` | 1 per person per client family per hour | `client` (bucketed, else `other`) |
| `plugin_linked`, `api_key_created`, `mcp_oauth_granted` | one-shot milestones | none | none |

Throttling is `EngramWeb.RateLimiter` (Hammer fixed window, epoch-aligned,
cluster-shared under `:distributed_ets`), so two events can land seconds apart
across a window edge. `mcp_tool_called` therefore measures **minutes a tool was in
use**, not call count.

Call seams: `EngramWeb.Plugs.WebActivity` (web; in `:authed_api` and the user
scope), `crdt_channel.ex` `note_sync_activity/1` (edits only), `mcp_controller.ex`
`emit_tool_analytics/3` and `emit_client_connected/2`.

## Definitions that are easy to get wrong

- **`obsidian_sync` means "pushed an edit", not "connected".** Join and
  handshake frames are excluded on purpose: an idle plugin reconnects and
  handshakes every note without the user doing anything. A user who only
  *receives* changes is invisible.
- **`web` is "authenticated by Clerk"**, derived by elimination in `WebActivity`
  (no `current_api_key`, `current_auth_method != :internal_jwt`). A legacy HS256
  JWT would also count as web. MCP uses an OAuth (internal JWT) token, so it is
  excluded.
- **Unknown client or tool names never reach PostHog.** Both are bucketed to an
  allowlist. Keep it that way: an arbitrary string becomes a property value.

## Identity: two id formats, cut over 2026-09-23/24

Server events used the raw Clerk id (`user_...`) until 2026-09-23, then the keyed
HMAC `PostHog.analytics_id(email)` (64 hex chars) from 2026-09-24. Anything that
filters `distinct_id LIKE 'user_%'` has read **zero** since the switch. The
Engram Business tiles were stale for that reason until 2026-10-03.

- Count people with `person_id`, not `distinct_id`, **except** when mixing
  formats: the same human has a different person on each side of the cutover, so a
  union double-counts. Tiles that straddle the cutover (Activated, MAU) count
  hashed ids only and under-read until the window is fully post-cutover
  (Activated 2026-10-24, MAU 2026-10-29).
- Identified vs anonymous: a 64-hex id is identified, a `user_%` id is legacy, and
  anything else is marketing traffic.

## Reading PostHog from here (no key needed)

Grafana's `PostHog API` datasource (`infinity-posthog`) has a **read** key, and its
base URL already includes the project (`.../api/projects/411782`). So a panel or
`/api/ds/query` body uses `url: "/query/"`, **not** `/api/projects/.../query/`
(that 404s). POST a `HogQLQuery` and project columns with a JSONata root selector:
`$.results.{"a": $[0], "b": $[1]}`. `/api/ds/query` returns field columns in
alphabetical order, not select order.

## Excluding internal accounts

Dashboards drop staff, all `@engram.page` addresses and comped friends with
`left(distinct_id, 16) NOT IN (...)`: the first 16 hex chars of each hashed id
(2^-64 collision risk, and it keeps every query short). The list is fixed in each
panel's query, so **a new internal account counts as a real user until its prefix is
added**. To compute one, HMAC-SHA256 the lowercased email with the prod
`hmac_key_analytics_id` from `engram-infra/secrets/prod.enc.yaml`. Do it inside one
subprocess so the key never reaches stdout (see `sops-operator-guide.md`).

## Traps hit building this

- **sobelow pins by file:line.** Adding a line above the `:spa` pipeline in
  `router.ex` moved a reviewed `Config.CSP` finding from `:185` to `:186`, so
  `lint` failed. Re-pin that one line in `.sobelow-skips`, don't suppress.
  See `sobelow-silent-no-op-and-fingerprint-skips.md`.
- **A request that emits two events breaks `expect_once`.** An authenticated web
  request now sends `surface_active` as well as the event under test. Use
  `Bypass.expect` and match by event name (`emitters_test.exs`).
- **A fresh backend worktree may not get its deps.** The post-checkout hook did
  not fire; hardlink `deps/` and `_build/` from the canonical checkout, run
  `mix deps.get`, then `MIX_ENV=test mix deps.compile --force` if beams are stale
  (symptom: `:expo_po_parser is not available`).
- **Plugin-version gate in tests.** A channel test joining with a made-up
  `plugin_version` is refused with `plugin_upgrade_required` below the floor.
