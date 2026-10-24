# Context Doc: Account deletion never waits on Qdrant

_Last verified: 2026-10-24_

## Status

Working. Fixed by #2188 (merged 2026-10-24, closes #2182 and #2187).

## What This Is

How `DELETE /api/me` (and the Clerk user-deleted webhook) remove an account
without calling Qdrant inside the request, and how to read the e2e symptom
that the old design produced.

## Symptom

`e2e-crdt` goes red on **every branch at once** with
`test_62 test_member_delete_blocks_future_login`
(`e2e/tests/api_only/local/test_62_local_account_settings.py`): the DELETE
answers 410 with the "auto-deleted after 90 days of inactivity" copy.

When every branch fails the same test at the same time, suspect shared CI
infrastructure first, not the branches. Here it was the shared CI Qdrant on
SlowRaid stalling (2026-10-24 08:00-08:20 UTC). The stall correlated with
SlowRaid's NVMe cache to array copy (the Unraid mover or the nightly backup,
around 02:00 local). Not proven causally; the timing matched.

## Root cause

`DELETE /api/me` ran `soft_delete` then `hard_delete`, and each cleared the
user's Qdrant points synchronously (5 s `:search` budget each). A stalled
Qdrant made the request take 10.3 s. The e2e client's urllib3 `Retry` then
replayed the DELETE after its read timeout; the replay found the account
already deleted and got 410. Two bugs: a request that depends on an external
store's latency, and a test harness that retried a non-idempotent method.

## As built (#2188)

- One entry point: `Engram.Accounts.Lifecycle.delete_account/2`
  (`lib/engram/accounts/lifecycle.ex`), for `:user` and `:clerk`. It marks the
  account deleted and runs `hard_delete`. No soft-delete Qdrant drop, so the
  redundant second clear is gone.
- The vector purge is a job: `Engram.Workers.PurgeUserVectors`
  (`lib/engram/workers/purge_user_vectors.ex`, queue `:events`, 20 attempts).
  It is inserted **inside** the delete transaction (`enqueue_vector_purge!/1`);
  a failed insert rolls the delete back rather than strand the points. A
  rolled-back delete therefore never leaves a live user with no points.
- `Engram.Workers.OrphanSweep` is the backstop: it reaps points of any user id
  with no `users` row, once a day. Until the purge runs the points are
  unreachable, because every search is scoped to a live user.
- The inactivity soft-delete keeps its own inline Qdrant drop; it runs in the
  background, not in a request.
- 410 copy: one neutral message in `AccountDeleted.deny/1`. The row does not
  record why it was deleted, so the old inactivity copy was wrong for every
  user-initiated delete.

## e2e retry policy

`e2e/helpers/http_retry.py` is the single retry policy for e2e HTTP clients:
read retries off (`read=0`), status retries only for idempotent methods
(GET/HEAD/PUT/OPTIONS) unless a caller widens the list, connect retries kept.
The Clerk client widens it to POST/DELETE only to retry a 429. Do not add a
per-test `Retry`; use `RetryClient`. Pinned by `e2e/unit/test_http_retry.py`.

## Gotchas

- Rule for any request path: do not call Qdrant (or any external store) inline
  when the work can be a job queued in the same transaction.
- Retrying a DELETE or POST after a read timeout is not safe: the first one may
  have committed. A 410 or 404 on a retry usually means the original worked.
- Rolling back to a build without `PurgeUserVectors` strands queued jobs;
  OrphanSweep collects those points the next day.
- Clerk webhook last-admin refusal leaves the account soft-deleted with its
  vectors kept (unreachable) until ops finish the delete.

## References

- PR #2188, issues #2182, #2187
- `test/engram_web/controllers/users_controller_test.exs` "a stalled Qdrant
  does not hold the request; the points are purged after"
- `docs/context/qdrant-orphan-points-rename-delete-race.md`
