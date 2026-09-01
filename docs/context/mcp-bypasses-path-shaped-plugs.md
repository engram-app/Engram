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
search allowance. Fixed by engram#1527.

**Being on the shared pipeline is not the same as running.** The pipeline
guarantees the plug is *invoked*; a path guard inside it decides whether it
*does anything*.

## Second instance: `attachments_enabled` (engram#TBD)

Same class, no plug involved — the gate was in a **controller action**.
`AttachmentsController.rename/2` checked `attachments_enabled` and then called
`Engram.Attachments.move_attachment/4`. The MCP `move_attachment` tool calls
that same function directly, so REST was refused and MCP was not.

The gate now lives in `move_attachment/4` itself, ahead of the row lookup (so a
revoked plan cannot be probed for which attachment paths exist). Both callers
inherit it and differ only in rendering: 402 via `LimitResponse` on REST,
`isError: true` with `attachments_enabled: not on your plan` on MCP.

### The carve-out, and why it is not a hole

The gate sits on `move_attachment/4`, NOT on the private `do_move_attachment/4`
underneath it. That inner function is also the per-item step of
`Attachments.rename_folder/4`, which `Folders.rename/4` runs after
`Notes.rename_folder/4` on **every** folder rename, REST and MCP alike.

Gating the shared mover (the first version of this fix did) refused the
attachment leg, `move_pairs/4` rolled the batch back, and `Folders.rename/4`'s
surrounding transaction took the note rename with it — so a revoked attachments
grant read as "you cannot rename a folder", with `:feature_not_available`
surfacing through an error path neither controller handles.

So: gate the **user-initiated entry points** (`move_attachment/4`,
`batch_move/4`), leave the internal cascade ungated. Relocating an attachment
the user already owns, as bookkeeping for a note-folder rename, is not "using
the attachments feature". `Engram.AttachmentsTest`, describe
`"attachments_enabled gates user moves, not the internal cascade"`, pins all
three directions.

Generalise: "push the gate down to where every caller routes through" is the
right instinct, but *every caller* includes the internal ones. Check what else
calls the function before you move a check into it — a server-side cascade
inherits the gate silently and fails somewhere with no vocabulary for it.

`upload/2`'s `attachments_enabled` and `attachments_all_types` checks stay in
the controller: HTTP upload is the only way to create an attachment (MCP's
`get_attachment_upload_target` just returns instructions pointing back at
`POST /api/attachments`), so there is no second caller to miss.

## The backstop that now covers this

`Engram.Billing.LimitEnforcementTest` has a third test: **a gated key whose
every `Billing.*` call site is under `lib/engram_web/` fails.** That directory
is plugs, controllers and channels — all transport. A key gated only there is
gated for whoever knocks on that door and nobody else.

`@transport_scoped` exempts the six keys where the endpoint genuinely IS the
operation: `api_write_enabled` / `api_rps_cap` (defined in terms of API-key
auth, which no context can see) and the four device/connection caps (OAuth
consent and device-flow authorize are the only paths that mint a connection).

Verified by mutation: deleting the `check_feature` line from
`move_attachment/4` fails the test naming `:attachments_enabled`.

## Why the tests did not catch it

`test/engram_web/plugs/enforce_search_cap_test.exs` calls `EnforceSearchCap.call/2`
directly on a synthesized conn whose `request_path` is already `/api/search`. It
proves the rule, never the routing. A unit test that hands the plug the exact
conn shape it pattern-matches on can never discover that no real request has
that shape.

The regression tests added with the fix drive `POST /api/mcp` through the real
router (`test/engram_web/controllers/mcp_controller_test.exs`, describe
`"external_ai_searches_per_day over MCP"`).

## Superseded for search (2026-09-01): charge at the cost site

`EnforceSearchCap` and `Engram.Usage.SearchCap` are **deleted**. The search
budget is now charged inside `Engram.Search.search/4` — the single funnel every
retrieval passes through, and where the Voyage embed happens.

That inverts the default. The old shape was "explicitly charge these two tools,"
against a hand-maintained `MCP.Tools.search_tools/0` list plus a test watching
the list. The new shape is "every retrieval is charged unless it passes
`charge: false`," so a new transport or tool inherits metering instead of needing
to be added to anything. `SearchToolCoverageTest` is deleted with the list.

`ConversationMeter` is gone too: six catalog keys collapsed into one
(`ai_searches_per_day`, Free 20). See `limit-sentinel-decoding.md`'s sibling
note and `Engram.Billing.LimitKeys`.

The rest of this doc still stands as the record of the bug class and as the rule
for any limit that is NOT a retrieval — an attachment cap, a device cap, a
connection cap all still live behind plugs or context functions and can still be
missed on a transport.

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

## Residual hole: uncharged searches via the write path

`auto_place_folder/4` is exempt on purpose (see below), and that leaves the cap
partially evadable. Repeated `write_note` against an EXISTING path grows no note
count, so `notes_cap` never binds, and each call runs one uncharged search. The
ceiling is `ConversationMeter` (~250 tool calls/day), so a determined Free client
can reach roughly 250 searches/day against an intended 15.

Accepted, not overlooked. Charging it would fail note creation with a search-cap
error, which is a worse product than a bounded bypass that still costs the
attacker a write per search. If this ever needs closing, the lever is a separate
cheap bucket for write-path auto-placement, not folding it into
`external_ai_searches_per_day`.

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

## The backstops that did not catch it, and why

Two static checks were supposed to cover this class. Both had the same blind
spot in different forms; both are fixed alongside the bug.

**`Engram.Billing.LimitEnforcementTest`** asserted only
`String.contains?(blob, ":#{key}")` over `lib/`. The key merely had to APPEAR
somewhere, in any context — a moduledoc mention, an `@unenforced` reason
string, or a call site no request can reach all passed equally.
`:external_ai_searches_per_day` appeared in the dead plug branch, so the guard
was green the entire time the cap was unenforced. It now walks the AST and
requires a real `Billing.{effective_limit, check_limit, check_feature,
limit_enforced?}` call with the key as an atom literal.

That raises the floor from "the string exists" to "a gate exists". It still
cannot prove the gate is REACHABLE — only a test that drives the actual route
or worker does that.

**A stale `@unenforced` entry is worse than none.** `cross_vault_search` sat in
that exemption list as "legacy UX flag; no per-request gate point yet" long
after `Engram.Search.cross_vault_allowed/2` started gating it, and nothing
failed when the comment went stale. A second test now asserts the exemption
list contains no key that is in fact gated, and
`Engram.Search.CrossVaultGateTest` pins both the gate and its one deliberate
MCP bypass.

**`mix engram.lint.limit_keys`** skipped piped call sites. `Code.string_to_quoted!/2`
does not expand `|>`, so `user |> Billing.effective_limit(:notes_cap)` parses as a
call with a single argument, fell through the `[_user, key | _rest]` clause, and hit
a catch-all commented "arity mismatch — ignore". A typo'd key in that shape was
silently unlinted: exactly the thing the lint exists to catch. Now handled.

## How to actually prove a limit

Mutation is the cheap check. Delete the gate line and run the suite:

```
# before adding a test, confirm the current suite does NOT catch this
$ <remove the `:ok <- SomeGate.check(...)` line>
$ mix test test/path/to/relevant_test.exs
```

If it stays green, the limit is unproven no matter how many unit tests the
gate's module has. `ConversationMeter.tick/1` had 8 unit tests and could be
deleted from `McpController.dispatch/3` with 91 tests still passing.

Match the test to where enforcement lives — a route test for a plug or
controller gate, a worker test for `EmbedNote` / `InactivityCleanup`, a context
test for `Accounts.Export` or `Search`. A conn-driving test is the wrong lens
for a worker-enforced key and will report a false gap.
