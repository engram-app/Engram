# Ordered Cursor Sync — device cursors + keyset pull + snapshot bootstrap + client migration

**Date:** 2026-06-16
**Status:** Design — approved for planning
**Repos:** `engram` (backend + `frontend/`) and `engram-obsidian-sync` (plugin)
**Branch:** `feat/sync-cursor-pull` (engram) + paired plugin branch
**Builds on:** PR A (merged, #622, `2b770e80`) — the `seq` substrate.
**Implements:** the spec's rollout steps **B + C + client migration**, framed as one
feature (the backbone is useless until something reads `seq`). See the parent
design `docs/superpowers/specs/2026-06-16-sync-change-log-backbone-design.md` for
the full model + the consistency-model decision — not repeated here.

## Problem

PR A stamps a per-vault monotonic `seq` on every write, but **nothing reads it** —
the timestamp `/changes?since` feed is still primary, with all its holes (no total
order, rename resurrection, no month-stale convergence). This feature makes the
ordered log *readable and authoritative*: a per-device cursor pull (`seq > cursor`)
plus a snapshot bootstrap, and migrates the plugin + web to use them. That delivers
ordered, convergent multi-device sync — the original goal.

## Decisions (locked during brainstorming)

1. **`device_id` = a random per-install UUID**, minted + persisted by each client
   (plugin data / web localStorage), sent via an `X-Device-Id` header. **NOT** the
   plugin's existing `clientId` — that is a SHA-256 of the vault *path* (`plugin/
   src/main.ts:46`), so two devices sharing a path collide; it's a vault-location
   key, not a device key. A reset/reinstall → new `device_id` → one clean
   re-bootstrap (safe).
2. **Stateless cursor, opaque token, pull-carries-ack.** The client owns its
   position (it alone knows what it durably applied) and sends an opaque cursor
   token (base64 of `seq:id`) each pull; the server is a pure function
   `(cursor) → page`. The token a client sends *is* its ack ("applied up to here"),
   so the server updates the device's watermark from it. No separate ack endpoint.
3. **Wipe + re-sync pre-launch** — no backfill. Dropping/recreating DBs re-stamps
   `seq` on every row via the normal write path, so legacy `seq IS NULL` rows never
   reach the cursor pull. (#623 backfill is therefore unneeded for launch.)
4. **One feature, sequenced PRs** — backend (cursor + bootstrap) → plugin → web.
   The timestamp feed stays primary until a later PR retires it (rollout step E).
5. **Manifest-authoritative bootstrap with a three-way reconcile** (closes the
   "local-only → re-push/resurrect" weakness — see §F).
6. **Attachment `version` column** added for resurrection-parity with notes.

## Non-goals

- **Compaction / GC** (rollout step D) — `vault_device_cursors` records the
  watermark this feature needs, but the low-water-mark Oban job is a later PR.
  `HISTORY_EXPIRED` ships wired but **dormant** (no compaction yet → never fires).
- **Retiring the timestamp feed** (step E) — coexists here.
- Version vectors / CRDT / P2P (settled in the parent spec).

## Architecture

### A. `device_id`
- Plugin: mint `crypto.randomUUID()` once, persist in plugin data (new field,
  *separate* from `clientId`), send `X-Device-Id` on cursor pull. Mobile + desktop
  each get their own.
- Web: mint + persist a UUID in `localStorage`, send the same header.
- Backend: read the header in the vault-scoped pipeline; absent/blank → the pull
  still works (stateless) but no watermark row is written (a watermark needs a
  device to attribute to). Treat a missing `device_id` as a soft degrade, logged.

### B. `vault_device_cursors` (Postgres, RLS-scoped)
```sql
CREATE TABLE vault_device_cursors (
  vault_id     uuid        NOT NULL REFERENCES vaults(id),
  device_id    text        NOT NULL,
  last_seq     bigint      NOT NULL DEFAULT 0,
  last_seen_at timestamptz NOT NULL,
  PRIMARY KEY (vault_id, device_id)
);
```
Updated as a **side effect** of a pull (upsert `last_seq` from the incoming
cursor's seq, `last_seen_at = now()`). It is the GC-watermark + eviction record —
**never** the pagination source of truth (that's the client's token). `phase/expand`.

### C. Keyset pull
`GET /changes?cursor=<token>` (or no token → bootstrap, §E):
```sql
-- token decodes to (cursor_seq, cursor_id)
SELECT ... FROM notes
WHERE vault_id = $1 AND (seq, id) > ($cursor_seq, $cursor_id)
ORDER BY seq, id LIMIT $page
-- UNION the same over attachments; merge + sort by (seq,id); page across both
```
- Uses the existing `(vault_id, seq, id)` index (PR A) — index-ordered, no sort.
- **Tombstones included** (`deleted_at IS NOT NULL`) so deletes/renames propagate.
- Response: the page of rows (same dual-field metadata/content shape as today's
  feed) + a `next_cursor` token (the `(seq,id)` of the last row) + `has_more`.
- The dual-field payload (metadata-only vs +content) from `/changes` is preserved.

### D. Pull-carries-ack (watermark)
The incoming `cursor` token = "I have durably applied up to `(seq,id)`." On each
pull the server upserts `vault_device_cursors(last_seq = cursor_seq,
last_seen_at = now())`. The watermark therefore reflects **confirmed-applied**
state — compaction (PR D) can safely GC `seq <= min(last_seq)`. No ack endpoint.

### E. Snapshot bootstrap + `HISTORY_EXPIRED`
- **No cursor token** (new/reset device) → the client fetches the existing
  **manifest** (full path inventory, computed on-demand) + the vault's current
  `change_seq`, runs the three-way reconcile (§F), then sets its cursor to
  `(change_seq, MAX_UUID)` so the first incremental pull returns only `seq >
  change_seq`.
- **`HISTORY_EXPIRED`** — if an incoming `cursor_seq` is below the retention floor
  (oldest retained tombstone's seq; **0 until PR D compacts** → never fires yet),
  the pull returns `410 HISTORY_EXPIRED` → the client re-bootstraps. Shipping the
  response + handling now lets PR D turn on compaction without a client change.

### F. Manifest-authoritative three-way reconcile (the convergence fix)
On bootstrap the manifest is server truth, but a client may hold local files +
offline edits. Using the persisted **syncState baseline** (plugin already keeps
last-synced hashes per path) disambiguates the four cases:
- in manifest, not local → **pull**
- in local + manifest → content-compare → pull / 3-way-merge conflict (existing)
- in local, not manifest, **in baseline** → server-deleted → **delete local**
- in local, not manifest, **not in baseline** → created locally offline → **push**

This is the canonical fix for today's "local-only → always push" (which resurrects
server-deleted files). The web has no offline-edit story, so its bootstrap is the
simpler "manifest is truth, render it" case.

### G. Attachment `version` column
Add `version integer NOT NULL DEFAULT 1` to `attachments` (`phase/expand`) +
bump it on write, mirroring notes' optimistic-concurrency/resurrection-safety.
Wire the 409-on-stale-version path for attachment writes.

### H. Coexistence
The cursor pull is **additive** beside `/changes?since`. A client migrates by
switching its sync loop to the cursor pull + bootstrap; an un-migrated client keeps
using the timestamp feed. Both read the same rows. The real-time socket
(`sync:<user>:<vault>`) stays a latency accelerator; the durable cursor feed is
truth, so a reconnecting client always converges via pull.

## Data flow (incremental pull)
```
client (has cursor token T = (seq,id) it last applied)
  GET /changes?cursor=T   + X-Device-Id: <uuid>
        ▼
server: rows WHERE (seq,id) > T ORDER BY seq,id LIMIT p   (notes ∪ attachments, incl. tombstones)
        upsert vault_device_cursors(last_seq=T.seq, last_seen_at=now)   ← watermark/ack
        ▼
  → { rows, next_cursor, has_more }
client: apply rows in (seq,id) order (tombstone→trash, else write); persist next_cursor; repeat until !has_more
```

## Error handling / edge cases
- **Opaque token tampering / malformed** → 400; client falls back to bootstrap.
- **`device_id` rotation** (reinstall/reset) → new id → no cursor row → bootstrap.
- **Concurrent pulls from one device** → stateless + idempotent; both return pages
  for their sent cursor; watermark upsert is last-writer (monotonic via `GREATEST`
  to avoid a lagging pull regressing the watermark).
- **Shared-seq page boundary** → `(seq,id)` keyset handles ties (no drop/dup).
- **`HISTORY_EXPIRED`** dormant until PR D; handler exists so D is a no-client-change flip.
- **Manifest + offline local edits** → the §F baseline disambiguation prevents
  deleting offline-created files.

## Rollout / PR structure (sequenced; one spec)
- **PR B1 — backend**: `attachment.version` + `vault_device_cursors` + keyset pull
  + bootstrap/`HISTORY_EXPIRED` + watermark-on-pull. API-tested. Folds perf
  deferrals **#5** (partial index `(vault_id, seq) WHERE deleted_at IS NOT NULL`)
  and **#4** (coalesce batch-update `vaults` writes via one `+N RETURNING`).
- **PR B2 — plugin**: mint `device_id`; switch the sync loop to cursor pull;
  manifest-authoritative three-way bootstrap; `HISTORY_EXPIRED` handling.
- **PR B3 — web**: mint `device_id`; cursor pull; manifest bootstrap.
Each engram PR: one `phase/*` label, one `mix.exs` bump. Plugin PR: one manifest bump.

## Testing
**Backend (`mix test`):** keyset pull correctness (ties across page boundary;
notes∪attachments interleave by `(seq,id)`; tombstones surfaced); opaque token
round-trip + tamper→400; watermark upsert monotonic (`GREATEST`); bootstrap returns
manifest + current change_seq; `HISTORY_EXPIRED` boundary (floor=0 → never fires);
attachment `version` bump + 409-on-stale; tenant isolation on `vault_device_cursors`.
**Plugin (`bun test`):** device_id mint/persist; cursor advance + resume; the §F
three-way reconcile (the four cases — esp. server-deleted→delete-local and
offline-created→push); `HISTORY_EXPIRED`→re-bootstrap.
**E2E (`make e2e`, paired plugin branch):** two devices converge over the cursor
pull; a device offline across rename+delete+create reconnects and converges with
**no duplicate / no resurrection / no lost delete** (the headline win); a
server-side folder rename propagates both renamed rows + tombstones in one ordered
pull.

## Prerequisites / follow-ups
- **Pre-launch DB wipe** before this ships (re-stamps `seq`); #623 backfill then unneeded.
- **PR D (compaction)** turns on `HISTORY_EXPIRED` + bounds tombstones — next after this.
- **PR E** retires the timestamp feed once all clients are migrated.
- **#608** attachment actions resumes on top of this (move/delete become ordered feed entries).
