# MCP bypasses path-shaped plugs

**Trigger:** you are adding or reviewing a plan-limit / abuse gate that lives in a
plug, or a Free-tier cap is not firing for a user who is clearly over it.

## The trap

`EngramWeb.Plugs.EnforceSearchCap` sat on the shared `:authed_api` pipeline —
the pipeline whose own comment says it is used by BOTH the REST scope and the
MCP scope "so a new security control can't be added to one and silently missed
on the other". It was still missed on MCP, because the plug's first clause is:

```elixir
def call(%Plug.Conn{method: "POST", request_path: "/api/search"} = conn, _opts)
```

MCP is a single route. Every tool — `search_notes`, `create_note`, all 21 of
them — arrives as `POST /api/mcp` with the operation named in the **JSON-RPC
body**, not the path. A plug matching on `request_path` therefore sees `/api/mcp`
and falls through to the `def call(conn, _opts), do: conn` catch-all for the
entire MCP transport.

Result: `external_ai_searches_per_day` (15/day on Free) was unenforced on MCP —
the exact client class the plug's own moduledoc named. The only remaining bound
was `ConversationMeter` (5 conversations x 50 queries = ~250 tool calls/day, and
every tool counts, not just searches), so Free got roughly 16x its intended
search allowance. Fixed by engram#1506.

**Being on the shared pipeline is not the same as running.** The pipeline
guarantees the plug is *invoked*; a path guard inside it decides whether it
*does anything*.

## Why the tests did not catch it

`test/engram_web/plugs/enforce_search_cap_test.exs` calls `EnforceSearchCap.call/2`
directly on a synthesized conn whose `request_path` is already `/api/search`. It
proves the rule, never the routing. A unit test that hands the plug the exact
conn shape it pattern-matches on can never discover that no real request has
that shape.

The regression tests added with the fix drive `POST /api/mcp` through the real
router (`test/engram_web/controllers/mcp_controller_test.exs`, describe
`"external_ai_searches_per_day over MCP"`).

## The rule

A limit that must hold across transports lives in a **plain module**, not in a
plug. `Engram.Usage.SearchCap.spend/2` owns both the bucket choice
(external vs in-app) and the spend; the plug and `EngramWeb.McpController` each
call it and only differ in how they render a denial (402 via `LimitResponse` on
REST, JSON-RPC `-32_005` on MCP).

When you add a cap, ask: **can this operation be reached over MCP?** If yes, the
plug is at most half the gate. Grep the MCP handlers for the underlying context
call (e.g. `grep -rn "Search.search(" lib/`) and confirm every call site is
covered — MCP handlers call `Engram.*` contexts directly and never re-enter the
HTTP stack.

## Deliberate exemptions (do not "fix" these)

- **`auto_place_folder`** (`Engram.MCP.Handlers`, reached from `create_note` /
  `write_note`) runs a search internally for folder auto-placement. It is NOT
  charged to the search bucket: the search is incidental to a write, is not the
  abuse vector, and charging it would fail note creation with a search-cap error.
- **`cross_vault_search`** is a Pro feature on REST but is deliberately bypassed
  on MCP via `allow_cross_vault: true` — multi-vault search is the MCP default
  on every tier (product decision 2026-07-10). See `Engram.Search.cross_vault_allowed/2`.

## Observability

There is still **no per-user usage counter** in Loki or Prometheus, and
`Billing.plan_state/1` returns caps only, never current counts — so "how close
is this user to their cap" is unanswerable from observability. The only signals
are:

- `engram_prom_ex_usage_daily_cap_total{kind,decision}` — allow/deny/fail_open
  counts per bucket, from `Engram.Usage.DailyCap` (no `user_id` tag, by design).
- `Engram.UsageMeters.notes_count/1` — DB-side, reachable only via ECS Exec + IEx.

Cap-reached events are returned to the caller (402 / `-32_005`), not logged, so
Loki will not show them either.
