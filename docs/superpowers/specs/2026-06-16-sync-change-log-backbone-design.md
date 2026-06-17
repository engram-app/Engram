# Sync Change-Log Backbone — ordered per-vault sequence + device cursors + compaction

**Date:** 2026-06-16
**Status:** Design — approved for planning
**Repos:** `engram` (backend + `frontend/`) and `engram-obsidian-sync` (plugin)
**Branch:** `feat/sync-change-log-backbone` (engram) + paired plugin branch
**Motivated by:** the parking issue #608 (attachment actions) — three independent
threads (attachment move convergence, month-stale vault convergence, unbounded
tombstone GC) all bottomed out at this missing foundation.

## Problem

Engram is a multi-device personal knowledge base: the same vault is edited from
several clients (Obsidian plugin on laptop A, laptop B, phone, web app), each
often offline for stretches, all syncing through **one central backend**. The
current sync is **timestamp-based** (`GET /changes?since=<updated_at>`) plus a
full-inventory **manifest** and a client-side **3-way content merge**. That
model has structural holes:

- **No total order.** `updated_at` has clock skew and ties; there is no
  authoritative ordering of changes within a vault.
- **Renames resurrect.** A server-side rename repoints a row in place; the poll
  feed emits only `{newPath}`. The plugin's reconcile treats a local-only path
  as *"push it up"* → the old path is **re-uploaded (resurrected)**. Today this
  is masked only by the real-time socket (which an offline client misses).
- **Month-stale vaults don't converge.** A client offline long enough relies on
  delete tombstones still being in the time-windowed delta; there is no cursor,
  no snapshot-authoritative bootstrap, and the reconcile's "local-only → push"
  cannot distinguish *created-here* from *deleted-there*.
- **Tombstones grow unbounded.** There is no mechanism to drop a delete marker
  once every device has seen it. No per-device cursor, no compaction.

## Goal

An **ordered, replayable, bounded** per-vault change-propagation backbone that
closes ordering, convergence (incl. month-stale), rename resurrection, and
unbounded retention — built on the existing Postgres + Oban stack, rolled out
**incrementally beside** the current timestamp feed (no flag day).

## Decisions (locked during brainstorming)

1. **Consistency model: server-authoritative ordered log** (a central per-vault
   monotonic sequence). The backend is the mandatory hub (clients never sync
   peer-to-peer), so total order is assigned by the server — no version
   vectors / CRDTs needed. Content conflicts keep the existing client-side
   3-way merge.
2. **Reuse the per-entity `version`** (notes already have it behind the 409
   version-conflict path) for resurrection-safety — a stale device re-uploading
   an old copy is detectable as old. Formalized, not reinvented.
3. **State-based change feed, NOT an event log.** One row per entity carrying
   its latest `seq`; a doc edited N times appears once at its latest seq. The
   entity tables *are* the feed — no separate append-only log table. Only
   tombstones linger and need GC.
4. **Storage: all Postgres + Oban.** A `change_seq` counter column on `vaults`,
   a `seq` column on `notes`/`attachments`, one new `vault_device_cursors`
   table, and an Oban compaction job. No new datastore, no Kafka/Redis stream.
5. **Version history is a separate, decoupled track** (see follow-up issue).
   The backbone leaves a clean per-entity version-bump hook but does **not**
   build the history feature; their retention semantics are opposite (sync
   history GC'd aggressively once devices converge; user history retained by
   product/pricing policy).
6. **Incremental rollout** — add `seq` alongside `updated_at`, dual-run, migrate
   clients to the cursor protocol, then deprecate the timestamp feed.

## Non-goals

- Direct device-to-device (P2P) sync — confirmed not a goal (clients always go
  through the backend).
- Real-time multi-cursor collaborative editing (CRDT territory; also collides
  with encryption-at-rest, where the server can't merge ciphertext).
- Full event-sourcing (store every edit) — rejected; state-based is sufficient
  for convergence and far cheaper.
- The **version-history feature** (see follow-up) — out of scope here.

## Architecture

### Data model (Postgres)

```sql
-- Per-vault monotonic counter (one column on the existing vaults row)
ALTER TABLE vaults ADD COLUMN change_seq bigint NOT NULL DEFAULT 0;

-- The change feed is the entity tables themselves, carrying their latest seq.
-- (folders are notes with kind='folder')
ALTER TABLE notes       ADD COLUMN seq bigint;
ALTER TABLE attachments ADD COLUMN seq bigint;
CREATE INDEX notes_vault_seq_index       ON notes       (vault_id, seq);
CREATE INDEX attachments_vault_seq_index ON attachments (vault_id, seq);
-- Tombstones = existing soft-deleted rows (deleted_at) that also carry a seq.

-- The only genuinely new table: the per-device sync cursor registry.
CREATE TABLE vault_device_cursors (
  vault_id     uuid        NOT NULL REFERENCES vaults(id),
  device_id    text        NOT NULL,
  last_seq     bigint      NOT NULL DEFAULT 0,
  last_seen_at timestamptz NOT NULL,
  PRIMARY KEY (vault_id, device_id)
);  -- RLS-scoped to the owning user, like every tenant table
```

`seq` and cursor rows are **plaintext metadata** — no payloads, so they sidestep
the encryption-at-rest model entirely. The feed still surfaces path/content as
the same ciphertext as today.

### Seq assignment (the one correctness rule)

The seq stamp and the row write happen in **one transaction**, so seq order ==
commit order, per-vault **monotonic**, and race-free. (Monotonic, not
gap-free: a rolled-back op un-bumps the counter, but a no-op re-push still
consumes a seq. Cursors/compaction only need monotonicity — `seq > cursor`
and `seq <= low_water` are correct over a gappy sequence — so gaps are
harmless. Don't build a contiguity assumption into compaction.)

```sql
BEGIN;
  UPDATE vaults SET change_seq = change_seq + 1 WHERE id = $vault RETURNING change_seq;  -- → s
  UPDATE notes  SET ..., seq = s WHERE id = $note;   -- or INSERT / soft-delete
COMMIT;
```

The row-level lock on the vault counter serializes seq assignment **per vault** —
trivially cheap for a personal vault with a handful of devices, and it is what
guarantees total order. Every accepted change (create, edit, delete, rename,
move, for notes / attachments / folders) goes through this stamp.

### Pull protocol (catch-up)

`GET /changes?cursor=<seq>` → `SELECT * FROM notes WHERE vault_id=? AND seq > ?
ORDER BY seq LIMIT <page>` (+ attachments), paginated by seq. Tombstones are
included (`deleted_at IS NOT NULL AND seq > cursor`) so deletes/renames
propagate as first-class entries. The client applies in seq order and advances
its cursor to the max seq applied, then **acks** (updates
`vault_device_cursors.last_seq` + `last_seen_at`).

The dual-field payload (metadata-only vs metadata+content) from the existing
`/changes` is preserved.

### Push protocol + per-entity version

Client writes carry the entity's expected `version`. The server bumps `version`
and stamps a fresh `seq` in the same transaction. A write against a stale
`version` returns the existing 409 conflict (→ client 3-way merge). A returning
stale device whose write carries an old `version` is recognized as old →
no resurrection. (Notes have `version` today; **attachments may need a `version`
column for parity** — see open questions.)

### Snapshot bootstrap + HISTORY_EXPIRED

- A new or reset device bootstraps from the **manifest** (the existing
  full-inventory snapshot, computed on-demand from rows) and sets its cursor to
  the vault's current `change_seq`. It does not replay from seq 0.
- A returning device whose cursor predates the oldest retained tombstone (its
  history was compacted away) gets `HISTORY_EXPIRED` and re-bootstraps from the
  manifest. Because the manifest reflects deletions as **absence**, deleted
  files simply are not present — **no resurrection** even though their
  tombstones were GC'd. (This requires the bootstrap reconcile to treat the
  manifest as authoritative — i.e. delete local files absent from it — which is
  the fix to the current "local-only → push" weakness.)

### Compaction + eviction (Oban)

A scheduled Oban job, per vault:

```
low_water = min(last_seq) over cursors WHERE last_seen_at > now() - ACTIVE_TTL
DELETE FROM notes       WHERE vault_id=$v AND deleted_at IS NOT NULL AND seq <= low_water;
DELETE FROM attachments WHERE vault_id=$v AND deleted_at IS NOT NULL AND seq <= low_water;
-- evict dead cursors so they can't pin the low-water mark forever
DELETE FROM vault_device_cursors WHERE last_seen_at < now() - EVICT_TTL;
```

- **ACTIVE_TTL** — devices silent longer are excluded from the low-water mark
  (so a dead laptop can't pin retention; the orphaned-replication-slot failure).
- **EVICT_TTL** (≥ ACTIVE_TTL) — fully drop the cursor; the device re-bootstraps
  via manifest if it ever returns.
- A safety **retention floor** may keep tombstones for a minimum window
  regardless, and a **ceiling** caps retention even for slow-but-active devices
  (a too-stale active device gets `HISTORY_EXPIRED`). Tunable.

Attachment tombstone compaction also confirms the blob is gone (already handled
by the storage delete path).

### Conflict handling

- **Structural** (create/delete/rename/move ordering) — resolved by `seq` order
  + per-entity `version`. The server's total order is authoritative.
- **Content** — unchanged: the client-side 3-way merge already in place. The
  server never reads plaintext (encryption-at-rest), so content merge stays on
  the client, which is exactly where it must live.

### Real-time layer (unchanged shape)

The existing `sync:<user>:<vault>` socket continues to push live changes; each
broadcast now also carries the `seq`. The socket is an **accelerator**, never
the source of truth — the durable seq feed + cursors are authoritative, so an
offline/reconnecting client always converges via pull regardless of missed
socket events.

## Incremental rollout (no flag day)

1. **Add `seq` beside `updated_at`** — stamp `seq` on every write; keep the
   timestamp feed working. Backfill existing rows with seq (pre-launch wipe
   makes this trivial; otherwise a one-time backfill assigns seq by
   `updated_at` order).
2. **Cursor protocol + registry** — ship `vault_device_cursors`, the
   `?cursor=` pull, and ack. Clients begin reporting a stable `device_id`.
3. **Snapshot-authoritative bootstrap** — implement `HISTORY_EXPIRED` +
   manifest-authoritative reconcile (delete local-absent), closing the
   month-stale gap.
4. **Compaction job** — enable Oban low-water-mark GC + eviction once cursors
   are populated.
5. **Deprecate the timestamp feed** — once all clients are on the cursor
   protocol.

Each step is independently shippable and reversible.

## Dependencies / interactions

- **Device identity** — needs a stable per-install `device_id` on sync
  requests. Engram has device identity for *auth* (`device_authorizations`,
  OAuth clients); this needs a sync-facing stable id. Relates to #374
  ("generalize device-flow connection metadata when a 2nd client ships").
- **Attachments** — gain a `seq` (and likely a `version`) column; the parked
  attachment-actions work (#608) is reframed: move/rename/delete become ordinary
  seq-stamped state changes + tombstones, and the ad-hoc per-entity tombstone
  mechanics (incl. the folder N+1 fan-out) **dissolve** into the uniform feed.
- **Encryption-at-rest** — seq/cursors are metadata (plaintext); payloads
  unchanged.
- **RLS** — `vault_device_cursors` is tenant-scoped like every other table.
- **Sync manifest reconciliation runbook** #264 — superseded/clarified by the
  snapshot-authoritative bootstrap here.

## Edge cases

- **Gap-free, race-free seq** — guaranteed by the in-transaction counter
  increment; no application-level sequence allocation.
- **Multi-vault** — `change_seq` is per-vault; cursors are per (vault, device).
- **Concurrent writers same vault** — serialize on the vault counter; throughput
  is trivial for personal vaults.
- **Clock independence** — convergence no longer depends on wall-clock; `seq` is
  the only ordering authority. `last_seen_at` is used only for TTL eviction
  (coarse, skew-tolerant).
- **Device id reuse / reinstall** — a new id bootstraps from manifest; the old
  cursor is evicted by TTL.

## Testing strategy (TDD)

**Backend (`mix test`):**
- In-transaction seq stamp: per-vault monotonic (gaps from no-ops harmless); concurrent writes
  serialize correctly.
- `?cursor=` pull returns rows + tombstones with `seq > cursor` in order;
  pagination by seq.
- Cursor ack updates `last_seq`/`last_seen_at`; tenant isolation.
- `HISTORY_EXPIRED` when cursor < retained floor; manifest bootstrap path.
- Compaction: drops tombstones ≤ low-water mark; respects ACTIVE_TTL (dead
  device excluded), EVICT_TTL (cursor dropped), retention floor/ceiling.
- Per-entity version: stale write → 409; old version not resurrected.

**Plugin (`bun test`):** cursor persistence + advance; apply in seq order;
manifest-authoritative bootstrap deletes local-absent files; HISTORY_EXPIRED
handling; echo-suppression unchanged.

**E2E (`make e2e`, paired plugin branch):**
- Month-stale convergence: device offline across a rename + delete + create,
  reconnect → converges with no duplicate / no resurrection / no lost delete.
- Compaction safety: tombstone GC'd while a device was active past it →
  returning device still converges via HISTORY_EXPIRED.
- Multi-device ordering: interleaved writes from two clients converge identically.

## Rollout / PR structure

Sequenced engram PRs (each + paired plugin changes where needed), mapping to the
rollout steps above:

- **PR A** — `seq` columns + counter + in-txn stamp + backfill (timestamp feed
  still primary).
- **PR B** — `vault_device_cursors` + `?cursor=` pull + ack + device_id from
  clients.
- **PR C** — snapshot-authoritative bootstrap + `HISTORY_EXPIRED` (closes
  month-stale).
- **PR D** — Oban compaction + eviction + retention knobs.
- **PR E** — deprecate timestamp feed; (optionally) resume #608 attachment
  actions on top of the new feed.

One `mix.exs` bump per engram PR; one plugin manifest bump per plugin PR.

## Follow-ups / related issues

1. **Version-history feature** (decoupled track) — retained encrypted revisions
   + restore UI + product/pricing retention. Its own issue/spec. The backbone
   leaves a clean per-entity version-bump hook; it does not build this.
2. **Device identity for sync** (#374) — stable per-install `device_id`.
3. **Attachment actions resume** (#608) — re-scope on top of the seq feed.
4. **Manifest reconciliation runbook** (#264) — fold into bootstrap semantics.
