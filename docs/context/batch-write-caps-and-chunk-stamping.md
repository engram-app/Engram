# Batch-write caps + chunk-stamped tombstones — the fewer-than-500-rows-per-TIMESTAMP invariant

_Last verified: 2026-08-01_

**Status:** shipped on PR #1188 (review-remediation bundle); #1194 (batch
write-path perf rewrite) builds on the same mechanism.
**Symptom class:** a legacy (pre-pagination) client's change-feed pull loops
forever on one page; or, the day-one version of the trap, e2e teardown gets
422 `batch_too_large` on a legitimate 1100-id bulk delete.

## The invariant

The legacy change feed (`GET /notes/changes`) pages by **timestamp** with an
**inclusive** boundary: legacy clients advance `since = server_time` after
every poll, and on a truncated page `server_time` is the last returned row's
`updated_at` (see `changes_server_time` in
`lib/engram_web/controllers/notes_controller.ex`). The `>= since` filter
re-serves the boundary row once; applies are idempotent, so that's fine —
**unless a page-size (500) or longer run of rows shares one `updated_at`
microsecond**. Because the boundary is inclusive, a run of EXACTLY 500 wedges
too: the page is entirely one stamp, `server_time` stays on that stamp, and
every subsequent poll returns the identical page.

So the real constraint is **STRICTLY FEWER than 500 rows per server
TIMESTAMP** — not ≤500 ids per request. Those are different things, and
conflating them is exactly the trap below. (The exactly-500 off-by-one was
itself caught in #1188's review pass — the first fix chunked at 500.)

## The trap we hit (2026-08-01)

The backend-wide review remediation PR (#1188) initially added a 500-entry
422 cap on notes batch delete/move at the context boundary, reasoning from a
stale comment claiming the request was already "capped at the controller
(100)". **No such controller cap ever existed.** And the e2e harness is a
legitimate consumer of uncapped bulk deletes:

- `e2e/tests/api_only/test_76_batch_pagination.py` teardown sends all 1100
  seeded ids in **one** `POST /notes/batch-delete` request ("no documented
  cap on ids", per its own comment).
- `e2e/tests/test_77_bulk_first_sync.py` teardown bulk-deletes its ~1000
  `Bulk/*` notes deliberately via batch-delete instead of 1,000 paced
  DELETEs — its docstring documents why: no time budget, no rate-limit
  starvation (bodies are chunked at 500 ids purely against request-size
  limits, but it is still bulk, not paced).

The cap broke e2e on day one.

**LESSON: the e2e harness is an API consumer.** Before changing any endpoint
contract (caps, status codes, param semantics), grep `e2e/` for usage — not
just `frontend/` and the plugin.

## The fix — chunk-stamp instead of reject

`batch_delete_notes/3` (`lib/engram/notes.ex`) now accepts any request size
and enforces the invariant directly: tombstones are stamped in
`@stamp_chunk` (400) id chunks, each chunk getting a **distinct**
timestamp — `base_now = DateTime.utc_now()` plus `i` microseconds per chunk
index, guaranteeing distinctness even when consecutive `utc_now()` calls
collide. 400 sits comfortably under the strict <500 bound. All chunks run
inside the one transaction and share one `seq` (notes batch-delete has
always allocated a single `Vaults.next_seq!`; the paginated feed's
`(seq, id)` keyset uses a STRICT `>` comparison with an id tiebreak, so seq
ties of any size are safe there).

`batch_upsert_notes/3` stamps through the same grouping: each entry's row
gets `Notes.bulk_stamp(base_now, index)` (400 rows per stamp) instead of one
shared `now` — a full 500-entry batch on one stamp would be exactly the
wedge condition.

This also fixed a **pre-existing** wedge: before any cap existed, an
uncapped 1100-id delete already stamped an 1100-row same-timestamp tombstone
run — the legacy-loop hazard was live in prod the whole time. The 422 cap
would have masked it; chunk-stamping removes it.

`batch_move_notes` needs neither cap nor chunking: moves update per-note
with per-note stamps, so no same-stamp run can form. Its cap (and the dead
422 clauses in the controller) were removed.

## Where caps remain, and why

- **`batch_upsert_notes` hard-caps at 500** (`@max_batch_entries`,
  `{:error, :batch_too_large}` → 422). Each entry costs an encrypt + a CRDT
  merge, so unbounded requests are a compute-DoS vector — and no legitimate
  client sends >500 (the plugin chunks at ≤100).
- **`Attachments.batch_delete/3` caps at 500 paths**
  (`lib/engram/attachments.ex`). Its legacy `list_changes` feed has no
  since-pagination loop, so the wedge class doesn't apply — but no bulk
  consumer exceeds the cap either, so it stays as a cheap guard.

The rationale lives next to `@max_batch_entries` in both modules; if you
touch either cap, update those comments and this doc together.

## Pointers

- PR #1188 — the mechanism (chunk-stamping, cap removal, the review bundle)
- PR #1194 — batch write-path perf rewrite building on it
- `lib/engram/notes.ex` — `@max_batch_entries` comment + `batch_delete_notes/3`
- `lib/engram_web/controllers/notes_controller.ex` — `changes_server_time`
  comment (the convergence bound, spelled out)
