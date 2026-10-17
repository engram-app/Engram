# API access and MCP limits: one cost meter, every tier, every credential

_Last verified: 2026-10-14 (#1974)_

**Read this before** adding a plan gate on API keys or MCP, re-adding a
connection cap, or answering "is the API Pro-only?" (it is not).

## The model

A personal API key works on **every route** (REST, `/api/mcp`, the sync
sockets) on **every tier**. A user may hold **any number** of MCP
connections, OAuth grants and API keys alike. Nothing is gated by which
credential called; cost is metered where it is incurred.

| Limit | Free | Starter | Pro | Where it is enforced |
|---|---|---|---|---|
| `ai_searches_per_day` (THE cost meter) | 20 | unlimited | unlimited | `Engram.Search.search/4`, every transport |
| `notes_cap` | 3,000 | 50,000 | unlimited | note writes |
| `api_rps_cap` (API-key traffic, per user per second) | 30 | 30 | 30 | `RequireApiRpsBudget`; `0` also refuses API-key sockets (`ChannelGate.api_access/2`) |
| `PreAuthRateLimit` (per endpoint family) | 600/min | 600/min | 600/min | `:authed_api` pipeline |
| `obsidian_connections_cap` / `concurrent_devices` | 2 | unlimited | unlimited | OAuth consent / device-flow authorize (UNCHANGED) |
| MCP connections | unlimited | unlimited | unlimited | none (removed) |
| `api_write_enabled` | — | — | — | removed |

Every stored note is searchable on every tier. The separate search-coverage
cap (`indexed_notes_cap`, 2,000 on Free) was removed on 2026-10-17, when Free
`notes_cap` dropped from 10,000 to 3,000. Notes it had skipped re-index on
their own through `ReconcileEmbeddings` (it selects every note with no dense
hash). `plan_state.indexed_notes_cap` (always `nil`), `/billing/usage`
`indexed_notes` (`limit: nil`), `/api/index-status` and bootstrap
`index_status` (always zeros) are compat shims for older plugins and SPA
bundles, to remove in a later contract PR.

`api_rps_cap` stays a limit key rather than a constant so a per-user
override can lift it, or set it to `0` as a kill switch for one abusive key
owner (REST and socket both refuse).

## Why

- **A connection costs nothing.** An idle OAuth grant or key is a row. What
  costs money is retrieval (Voyage embed + Qdrant), which the
  `ai_searches_per_day` meter already charges at the cost site, for every
  transport and credential (#1527 is why it lives there and not in a plug).
- **The MCP connection cap broke reconnects.** Free had 1 MCP connection. A
  connector whose grant died (the refresh failures #1974 is about) could not
  be re-authorized: the new consent counted against the cap held by the
  dead grant and got a 402. The user saw "upgrade" for a bug of ours.
- **Pro-only API keys pushed users onto broken paths.** An API key is the
  fallback for MCP clients whose OAuth flow is broken (Muse, key-oriented
  clients). Gating it to Pro removed the fallback exactly where OAuth
  failed most.
- **Gating by credential is leaky anyway.** `RequireApiWriteEnabled` was
  never mirrored on sockets (`ChannelGate` documented the open write gap),
  and MCP-over-OAuth was never gated at all. One meter at the cost site has
  no such bypasses.

## Removing a limit key is upgrade-safe

`mcp_connections_cap` and `api_write_enabled` were deleted with **no data
migration**. `Billing.effective_limit/2` looks up only the key it was asked
for (override → env → plan → default), so a leftover `user_limit_overrides`
row, a `plans.limits` JSON key or an `ENGRAM_<TIER>_<KEY>` env var naming a
removed key is never read, and `Billing.capabilities/1` iterates the
catalog, not the rows. Pinned by
`test/engram/billing/capabilities_test.exs` ("a leftover override row for a
removed key is inert") and `api_key_all_tiers_test.exs`.

The trap that DOES apply (see `self-host-capability-polarity.md`) is a
RENAME of a key whose restrictive value lives in override rows; a deletion
whose restriction is meant to vanish has nothing to preserve.

## Where the old gates were

Removed in #1974: `EngramWeb.Plugs.RequireApiWriteEnabled`,
`EngramWeb.Plugs.EnforcePatCreation` (key minting), the MCP branch of
`EnforceConnectionCap`, `caps.mcp_connections` / `caps.api_write_enabled` /
`current_connections.mcp` in `/billing/status`, and the frontend upsells
that read them.
