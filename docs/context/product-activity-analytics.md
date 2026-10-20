# Product activity analytics — who is using Engram, and how

_Last verified: 2026-10-20. Shipped in v0.39.0 (#1813). Dashboards: Grafana `engram-usage`, plus the DAU/MAU/Activated tiles on `engram-business`._

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
| `surface_active` | web request (Clerk session), pushed Obsidian or web-editor edit, any MCP call or handshake | 1 per person per surface per 5 min (web editor has its own window) | `surface` (`web` `obsidian_sync` `mcp`), `events`, plus `plugin_version`, `client_type`, `platform` from the CRDT socket |
| `mcp_tool_called` | MCP tool call (also argument-rejected ones) | 1 per person per tool per client per min | `tool` (allowlist, else `unknown`), `status`, `client`, `calls`, `errors` |
| `mcp_client_connected` | MCP `initialize` | 1 per person per client family per hour | `client` (bucketed, else `other`) |
| `plugin_linked`, `api_key_created`, `mcp_oauth_granted` | one-shot milestones | none | none |
| `device_connected` | every device-code exchange | none | `platform` (`desktop` `mobile`, else null) |
| `device_disconnected` | a device family or Obsidian OAuth grant revoked | none | `via` (`device_flow` `oauth`) |
| `mcp_client_disconnected` | an MCP grant or an API key revoked | none | `via` (`oauth` `api_key`), `client` (family, oauth only) |
| `note_created` | a REST or MCP write, or a web-editor CRDT create, makes a note | none | `vault_id`, `surface` (`web` `obsidian_sync` `mcp` `api` `welcome` `other`) |
| `vault_populated` | a vault gets its first non-welcome note | none | `vault_id` |
| `vault_created` / `vault_deleted` | a vault newly made / deleted | none | `vault_id`, `vault_number` / `vaults_left`, `surface` |
| `search_performed` | every search, served or refused | none | `status` (`ok` `refused`), `surface`, `result_count`, `latency_ms`, `cross_vault` |
| `limit_hit` | any 402 (`LimitResponse.halt/5`), CRDT `notes_cap`, a spent `ai_searches_per_day`, the silent embed budget | 1 per person per key per hour (embed budget: per day) | `limit_key`, `tier`, `surface`, `silent` (embed budget only) |
| `sync_error` | any authenticated 409, 413 or 426, and CRDT create refusals | 1 per person per kind per hour | `kind` (`conflict` `too_large` `upgrade_required` `id_conflict` `version_conflict` `recently_deleted`), `surface` |
| `signup_attributed` | the SPA posts `?via=`/`utm_*`/referrer domain once after sign-up | once (first touch) | the allowlisted fields, also `$set_once` with `signup_source: website` for a web signup |
| `first_sync_planned` / `first_sync_finished` | `POST /api/analytics/sync-summary` from the plugin (no plugin sends it yet) | 1 per person per phase per hour | counts (`notes` `attachments` `folders` / `total` `failed` `skipped` `duration_ms`), `choice`, `outcome`, `platform` |
| billing lifecycle | Paddle webhooks via `PostHogForwarder` | none | see below |
| `account_deleted` | account hard-deleted (anonymous, no person) | none | `tenure_bucket`, `plan`, `notes_bucket`, `surfaces_used`, `trigger` |

Billing (from Paddle webhooks): `subscription_trial_started`,
`subscription_started` (`tier`, `price_id`, `interval`, `discounted`),
`subscription_changed` (`kind`: `upgrade` `downgrade` `cancel_scheduled`
`reactivated`; a renewal sends nothing), `subscription_canceled`,
`subscription_past_due`, `payment_completed` (`amount_bucket`, `currency`,
`interval`, `discounted`, `origin`) and `refund_issued` (approved refund or
chargeback). Comped subs show as `discounted: true` with `amount_bucket: "0"`.
These also `$set` `plan` and `subscription_status`, but only once the privacy
policy gate below is in effect. `refund_issued` needs the Paddle notification
destination subscribed to `adjustment.created` / `adjustment.updated`.

Throttling is `EngramWeb.RateLimiter` (Hammer fixed window, epoch-aligned,
cluster-shared under `:distributed_ets`), so two events can land seconds apart
across a window edge. A throttled event that carries counts (`calls`,
`errors`, `events`) carries everything since the previous event for the same
key (`Engram.Analytics.Folds`, per-node ETS): sum them for exact volume. The
counts of the last window wait for the next event, so a sum can trail by one
window.

Call seams: `EngramWeb.Plugs.WebActivity` (web activity and `sync_error`; in
`:authed_api` and the user scope; `WebActivity.surface/1` is the one
credential-to-surface rule), `crdt_channel.ex` `note_sync_activity/1` (edits
only), `mcp_controller.ex` `emit_tool_analytics/3` and
`emit_client_connected/2`, `Search.search/4` (`opts[:surface]`).

## Customer-success funnel

`engram-usage` panel "Customer success funnel (signups, 30d)" (id 13): signed
up, accepted terms, connected (Obsidian or AI tool), first use (Obsidian push,
MCP tool call, or a non-welcome `note_created`), came back (`surface_active` on
2+ days), paid. The `engram-business` Activated tile uses the same "first use"
rule; DAU/MAU count `surface_active`. `user_signed_in` has never fired: the
Clerk endpoint is not subscribed to `session.created`, and `surface_active{web}`
already covers sign-in activity.

## Person properties (daily, `Engram.Workers.PostHogPersonSync`)

Since privacy policy 2026-10-12, PostHog persons are identified. A daily job
(06:25 UTC) `$set`s on every live user. It is gated on
`PersonProperties.policy_in_effect?/0` and sends nothing before 2026-11-11.

- Account: `email`, `name`, `signed_up_at`, `plan` (`free`/`starter`/`pro`,
  same rule as `Billing.tier/1`), `subscription_status`.
- Size: `vault_count`, `total_notes`, `total_note_bytes` (stored size:
  encrypted and maybe compressed), `total_attachments`,
  `total_attachment_bytes`, `largest_vault_notes`, `largest_vault_bytes`.
- Connections: `obsidian_devices` (live device families plus Obsidian OAuth
  clients), `obsidian_last_seen_at` (newest device-token refresh),
  `mcp_clients` (families with a live grant), `mcp_client_count`,
  `api_keys_count`.
- Usage and milestones: `embed_tokens_used`, `last_active_at`,
  `first_vault_at`, `plugin_connected_at`, `ai_connected_at`.

One `/batch/` request per 1,000 users. The `distinct_id` is still the HMAC
`analytics_id`, so no second identity cutover. There is no web-editor
last-used trait: nothing in Postgres records which client wrote.

- **Internal accounts:** filter by `email` in PostHog's "Filter out internal
  and test users" setting. No `is_internal` property exists on purpose.
- **Never add** note content, titles, paths, vault names or search text. The
  policy promises this.
- New users appear with properties after the next run (up to 24 h).

## Definitions that are easy to get wrong

- **`note_created` with `surface = 'welcome'` is OUR seed note**, fired for
  every new vault. Exclude it from any "the user created a note" query.
- **`note_created` does not see Obsidian CRDT creates.** Obsidian creates notes
  over `crdt_create`, which counts as `surface_active{obsidian_sync}` instead (a
  bulk import would otherwise send one event per note). Use `surface_active`
  for "synced from Obsidian", and `vault_populated` for when a vault got its
  first note. Web-editor creates do fire `note_created{web}`.
- **`limit_hit` and `sync_error` are throttled per key.** They answer "who hit
  it, and when first in the hour", not how often.
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
