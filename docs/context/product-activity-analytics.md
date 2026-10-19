# Product activity analytics — who is using Engram, and how

_Last verified: 2026-10-19. Shipped in v0.39.0 (#1813). Dashboards: Grafana `engram-usage`, plus the DAU/MAU/Activated tiles on `engram-business`._

Read this before touching `Engram.Observability.PostHog`, adding an event, or
trusting a "daily active users" number. For the **client-side** (posthog-js)
traps, see `posthog-instrumentation-traps.md`.

## One module: `Engram.Analytics`

Application code calls only `Engram.Analytics` (`track/3`, `track_activity/3`,
`track_throttled/5`, `track_anonymous/2`, `set_traits/1`, `forget/1`,
`client_id/1`). It owns opt-out, throttling and erasure, and re-reads the user
through the `:user` cache so a long-lived socket's stale struct cannot outlive
an opt-out or email change. `Engram.Observability.PostHog` is the vendor
adapter; `test/lint/analytics_boundary_test.exs` fails if anything else calls
it. Replacing PostHog means rewriting that one adapter.

## What is emitted (server-side, via `Engram.Analytics`)

| Event | When | Throttle | Props |
|---|---|---|---|
| `surface_active` | web request (Clerk session), pushed Obsidian edit, any MCP call or handshake | 1 per person per surface per 5 min | `surface` (`web` `obsidian_sync` `mcp`), plus `plugin_version` and `client_type` on `obsidian_sync` |
| `mcp_tool_called` | MCP tool call (also argument-rejected ones) | 1 per person per tool per min | `tool` (allowlist, else `unknown`), `status` |
| `mcp_client_connected` | MCP `initialize` | 1 per person per client family per hour | `client` (bucketed, else `other`) |
| `plugin_linked`, `api_key_created`, `mcp_oauth_granted` | one-shot milestones | none | none |
| `note_created` | a REST or MCP write creates a note | none | `vault_id`, `surface` (`web` `obsidian_sync` `mcp` `api` `welcome` `other`) |

Throttling is `EngramWeb.RateLimiter` (Hammer fixed window, epoch-aligned,
cluster-shared under `:distributed_ets`), so two events can land seconds apart
across a window edge. `mcp_tool_called` therefore measures **minutes a tool was in
use**, not call count.

Call seams: `EngramWeb.Plugs.WebActivity` (web; in `:authed_api` and the user
scope), `crdt_channel.ex` `note_sync_activity/1` (edits only), `mcp_controller.ex`
`emit_tool_analytics/3` and `emit_client_connected/2`.

## Person properties (daily, `Engram.Workers.PostHogPersonSync`)

Since privacy policy 2026-10-12, PostHog persons are identified. A daily job
(06:25 UTC) `$set`s on every live user: `email`, `name`, `signed_up_at`,
`plan` (`free`/`starter`/`pro`, same rule as `Billing.tier/1`),
`subscription_status`, `notes_count`, `vault_count`, `attachment_bytes`. One
`/batch/` request per 1,000 users. The `distinct_id` is still the HMAC
`analytics_id`, so no second identity cutover.

- **Internal accounts:** filter by `email` in PostHog's "Filter out internal
  and test users" setting. No `is_internal` property exists on purpose.
- **Never add** note content, titles, paths, vault names or search text. The
  policy promises this.
- New users appear with properties after the next run (up to 24 h).

## Definitions that are easy to get wrong

- **`note_created` with `surface = 'welcome'` is OUR seed note**, fired for
  every new vault. Exclude it from any "the user created a note" query.
- **`note_created` does not see CRDT creates.** Obsidian creates notes over
  `crdt_create`, which counts as `surface_active{obsidian_sync}` instead (a bulk
  import would otherwise send one event per note). Use `surface_active` for
  "synced from Obsidian".
- **The web editor also joins the CRDT channel** (`client_type: "web"`). Its
  edits count as `web`; only an Obsidian or untagged client counts as
  `obsidian_sync`. Before 2026-10-19 web edits were miscounted as `obsidian_sync`.
- **`obsidian_sync` means "pushed an edit or created a note", not "connected".** Join and
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

## Test traps

- **A request that emits two events breaks `expect_once`.** An authenticated web
  request now sends `surface_active` as well as the event under test. Use
  `Bypass.expect` and match by event name (`emitters_test.exs`).
- **Plugin-version gate in tests.** A channel test joining with a made-up
  `plugin_version` is refused with `plugin_upgrade_required` below the floor.
