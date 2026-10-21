# Context Doc: Qdrant strict mode rejects unindexed filters (permanent 400)

_Last verified: 2026-10-21_

## Status
Fixed in #2140 (incident #2138). Rules below keep it from recurring.

## Symptom
- Every Oban job that scrolls, searches or filters Qdrant on one key fails the same way, on every retry.
- Worker scroll errors step up by (affected users x max attempts). Here: +755 after :33 (151 users x 5 retries).
- Failure-rate alerts stayed quiet. The only lasting damage was data: 19,666 of 26,183 notes kept a NULL `payload_hash`.

## Root Cause
Prod Qdrant Cloud runs strict mode with `unindexed_filtering_retrieve: false`. Any scroll, search or filter on a payload key with no payload index returns HTTP 400. It is permanent, never transient, so retrying cannot help.

Incident #2138 (2026-10-21): `ReconcileNotePayloads` filtered on the v5 key `u` (`is_empty`) while v5 was off, so `u` had no index. Every job failed 5 of 5 retries for 151 users in an hour.

## How It Was Found
Read-only repro on prod with a dummy point id:
- `has_id` alone: 200
- `has_id` + `user_id`: 200 (`user_id` is indexed)
- `has_id` + `u`: 400

The 400 follows the unindexed key, not the filter shape or the collection.

## Rules
- Build every user/tenant filter through `Qdrant.match_filter(:user, ...)`. Never hand-write the filter map.
- A new filter key needs its payload index created BEFORE any reader uses it. That includes v5 flag flips: turning a flag on must not be the first moment a key is queried.
- The test fake Qdrant refuses unindexed keys the way prod does, so a test that filters on a new key without indexing it fails locally. Do not loosen the fake.
- Staging runs self-hosted Qdrant without strict mode, so e2e cannot catch this (see the related doc).

## Retry Policy
Qdrant errors map to Oban outcomes by status:
- 4xx: cancel the job (retrying a permanent 400 only burns attempts)
- 429, 503, 507: snooze
- other 5xx: back off and retry

## Gotchas
- A green failure alert proves nothing here. Cancel-on-4xx jobs and NULL-column counts are the signals to watch.
- Reconcile jobs that cancel leave rows unprocessed. After a fix, confirm the NULL `payload_hash` backlog drains.

## Related
- `docs/context/qdrant-payload-indexes-strict-mode.md` (index reconcile on boot, #1609)
