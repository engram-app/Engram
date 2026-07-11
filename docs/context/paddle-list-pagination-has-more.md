# Paddle list pagination: stop on `has_more`, never `next`

_Last verified: 2026-06-23_

How to paginate Paddle list endpoints without an infinite loop. Owner: billing. Status: fixed in PR #723.

## The gotcha

Paddle list endpoints (`/subscriptions`, `/transactions`, etc.) return a pagination block:

```json
"meta": { "pagination": { "per_page": 200, "next": "https://api.paddle.com/subscriptions?after=sub_xyz...", "has_more": false, "estimated_total": 45 } }
```

`meta.pagination.next` is **always present, even on the last page** — it is a resume *bookmark* (`after=<last_id>`), NOT a "there's more data" flag. The authoritative terminator is the boolean `meta.pagination.has_more`.

Paddle's docs say this outright (https://developer.paddle.com/api-reference/about/pagination):
- `next` — "Always returned, even if `has_more` is `false`."
- "Check `has_more` rather than inferring whether there are more pages from the presence of `next`."

**Rule: drive pagination off `has_more`. Never treat the presence/absence of `next` as the terminator.**

## How it bit us

`lib/engram/paddle/client/http.ex` `list_pages/6` (the `list_subscriptions/1` walker, used by the daily `PaddleReconcile` Oban worker) originally stopped only when `next == nil`/`""`. In prod that never happens, so it kept paging past the final page. Following `next` from the last page (`after=<last_id>`) returns a `next` URL that's already been fetched → the `seen`-MapSet infinite-loop guard tripped → `{:partial, ..., :pagination_loop}`.

Symptom: the daily page-severity alert `engram-prod-loki-billing-error` with `reason_label=pagination_loop`, firing ~02:00 UTC (the reconcile worker's schedule).

- Introduced #379 (2026-06-04).
- Only became *visible* after billing logs reached Loki via #707 (2026-06-23) — the loop had been silently degrading reconcile reads before then.
- Fixed in PR #723: stop when `has_more != true`; the `next` nil/"" check and the `seen` loop-guard + `@max_pages` cap are kept as defense-in-depth (they should now be unreachable in normal operation).

## The test trap

The original fixtures mocked `next: nil` to terminate the walk — a response **real Paddle never sends**. The bug shipped green because the test world didn't match prod.

**Any Paddle list mock MUST include `has_more`** (and should keep a non-nil `next` on the final page, matching real Paddle, so a test can't accidentally rely on `next` to stop).

## See also

- `docs/context/paddle-integration.md` — full Paddle wiring, the `PaddleReconcile` worker, and the drift-response runbook.
