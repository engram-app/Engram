# Context Doc: kwsearch writer traps (Tantivy keyword service)

_Last verified: 2026-11-26_

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

## How to check a change

- `cargo test -p kwsearch` (on SlowRaid, not the dev box). Widen the property test with `KW_SEEDS=5000`; isolate with `KW_SEED`, `KW_TRACE`, `KW_NOCRASH`, `KW_NOPURGE`, `KW_BIG`.
- `native/kwsearch/it/host.sh` with `B=<build dir>`: TLS Postgres harness (tls, replay, crash, panic, xid, restore; `bench` on request).
