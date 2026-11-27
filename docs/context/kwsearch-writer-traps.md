# Context Doc: kwsearch writer traps (Tantivy keyword service)

_Last verified: 2026-11-26 (bulk path added in P2 part 2)_

## Status

Working. Built in PR #2713 (P2 part 1 of the search storage roadmap). Each trap below was a real bug found by the property test or the integration harness, and each has a test that fails without its fix.

## What This Is

`native/kwsearch` applies the `keyword_feed` outbox to 256 Tantivy shards. The rules that keep it exact are easy to break by "obvious" edits. Read this before touching `native/kwsearch/src/{shard,feed}.rs`.

## Traps

1. **`xid::text` must be aliased in any query that also orders by `xid`.** `SELECT seq, xid::text, ... ORDER BY xid` sorts by the OUTPUT column, which Postgres names `xid`, so it sorts TEXT ("1000" < "883") while the `WHERE (xid, seq) > cursor` compares the real `xid8`. The cursor then skips rows for good once xids cross a digit-count boundary. The POC had this query and never crossed one. Fix: `xid::text AS xid_text`. Test: harness `replay` (lost 461 of 8,367 rows before).
2. **No Tantivy background merges.** With `LogMergePolicy` running in the background, a merge racing the next round's deletes brought deleted docs back (duplicate point docs, property test seed 343). The writer uses `NoMergePolicy`; `Shard::compact` runs the log-merge candidates (plus a 10% deleted ratio, F1) synchronously on a clean shard right after each commit.
3. **Never clear all in-memory note markers.** The POC cleared every marker on a vault or user delete. The next op of ANOTHER note in the same round then read its older committed marker and applied a stale pass as fresh, deleting the newer pass's points. Test: `a_vault_delete_between_passes_keeps_the_newer_marker`.
4. **A deleted user's later rows are no-ops, vault deletes included.** A `delete_vault` applied after the user's `delete_user` (higher xid, committed earlier) re-counted the user's stats. `apply` skips every row of a tombstoned user and only records the vault tombstone.
5. **Marker expiry bound is the snapshot xmax, not the marker's xid.** A stale pass committed BEFORE the marker's pass but holds a HIGHER xid, so "expire once the watermark passes the marker's xid" (roadmap 4g wording) drops markers too early. The bound that holds: the xmax of the snapshot the marker's row was read under.
6. **The deletion log is replayed only on a feed gap.** It has no note stamps, so replaying a note delete on a normal restart can delete a newer pass that took a lower xid and is already applied. On a gap (trim horizon above the node's cursor) the node stays down until a rebuild, so over-deleting there is harmless.
7. **"Drained" means the applied cursor reached the feed's last row.** `lag_s` reads 0 right after a drained read, before the next round commits. The harness waits on `GET /cursor` (ops token) instead; any future readiness check should too.
8. **In-process "crashes" must not leave writer threads alive.** Dropping a Tantivy writer in a test lets its merge thread save meta over the next writer's. The property test's crash is `Shard::crash` (rollback + wait for merges); real `kill -9` runs live in the harness.

9. **A bulk batch is ordered by the note marker, so the marker must outlive the feed's bound.** The bulk endpoint (backfill, reconcile) is not in the feed, so feed order does not protect it. Each batch note carries a stamp taken under the note's row lock; kwsearch drops it when the note's marker stamp is higher. The feed alone lets a marker go once the watermark passes its snapshot xmax (trap 5), which is seconds, but a batch may arrive up to `BULK_MAX_AGE_S` (1 h) after its read. So markers also stay `MARKER_HOLD_S` (1 h + 10 min skew) after apply, and `/bulk` refuses older batches (409 `stale_batch`). A per-doc stamp (the roadmap's first idea) is not enough: a pass that only REMOVES points, or a note delete, leaves no doc to carry the stamp, and the stale batch would bring the removed point back. Tests: `note_markers_outlive_the_watermark_for_the_bulk_window`, and the property test pushes bulk batches at random points between feed rounds.
10. **An equal bulk stamp is a continuation, not stale.** Stamps are unique per note op, so the same stamp twice is one batch note split across requests (a huge note) or a retry. It skips the leading point-set delete and applies the docs against the marker's keep set. Test: `a_bulk_note_split_across_requests_lands_whole`.
11. **`ready` needs a finished epoch.** A new index and any feed gap start a new epoch with `rebuilding: true` (`<data>/epoch`); `/health` stays down until the app's reconcile has bulk-loaded every user and posted `/rebuilt` with THAT epoch id. A restart keeps the state. An older epoch's `/rebuilt` is refused (409).
12. **A re-keyed upsert purges the shard once it settles (F5).** Same point id, different terms crc = a DEK rotation or tokenizer change; `rekey_at` is set and `purge_old` force-merges the shard after `REKEY_SETTLE_S` (10 min) with no further re-key.

13. **Reload the reader under the shard lock, before the in-memory markers go.** `/bulk` runs on HTTP threads against the same shard as the feed thread. A bulk call that took the lock between a commit and its reader reload read markers from the OLD searcher and brought back a point the just-committed pass removed (review H1). `commit`, `compact` and `purge` now reload while holding the lock. Test: `a_bulk_call_in_the_commit_to_reload_gap_sees_the_new_marker` (a hook pauses inside the commit).
14. **Markers are keyed by (user, note), in memory and in the index queries.** Keyed by note alone, a bulk body under user B's token naming user A's note set THE note's marker and made A's next fresh pass look stale (review M6).
15. **No wall clock crosses hosts.** A bulk batch carries `age_ms` from the app's monotonic clock; kwsearch adds its own wait since receipt and re-checks the bound under the shard lock (review M3).
16. **A split note's later parts are `cont`.** Only the first part carries the point set; a `cont` part applies only when its first part's stamp is the note's applied stamp, so a lost first part can never act as a fresh pass with an empty set.
17. **A gap moves the cursor to the horizon.** Without it an idle feed (no row above the horizon) re-detected the same gap after every `/rebuilt` and looped through full reloads (review M5).

## How to check a change

- `cargo test -p kwsearch` (on SlowRaid, not the dev box). Widen the property test with `KW_SEEDS=5000`; isolate with `KW_SEED`, `KW_TRACE`, `KW_NOCRASH`, `KW_NOPURGE`, `KW_BIG`.
- `native/kwsearch/it/host.sh` with `B=<build dir>`: TLS Postgres harness (tls, replay, crash, panic, xid, restore; `bench` on request).
