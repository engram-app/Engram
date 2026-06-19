# Context Doc: Sync protocol (server-side)

_Last verified: 2026-06-19_

## Status
Working — ordered change-log / cursor-pull sync, shipped 2026-06 (backend PRs #628–#630, plugin #109). Compaction (history GC) is the one unbuilt piece (PR D; `retention_floor` is 0 until then).

## What This Is
How the server lets a client (plugin or web SPA) converge a vault: a per-vault **ordered change-log** the client pulls forward via an opaque cursor, a **manifest** for first-sync/reconciliation, idempotent **bulk** ops, and a **WebSocket channel** for live nudges. The client holds its own position; the server is the ordered source of truth.

## Core model
- **`seq`** — a per-vault monotonic counter, `Engram.Vaults.next_seq!/1` (`vaults.ex:113`). **Every note and attachment write stamps the next seq.** It is unique across notes AND attachments within a vault, so ordering the union by `{seq, id}` is a **total order** (no cross-table collisions).
- **Cursor** — opaque `base64url("<seq>:<id>")` via `Engram.Sync.encode_cursor/2` / `decode_cursor/1`. The client stores it; the server never trusts a server-held position for pagination.

## Endpoints (all under `/api`, vault-scoped pipeline)
| Method/Path | Action | Purpose |
|---|---|---|
| `GET /sync/changes` | `SyncController.changes` | **Unified** ordered pull — merges the notes + attachments feeds into one `{seq,id}` page |
| `GET /sync/manifest` | `SyncController.manifest` | Full vault snapshot (path ciphertext + `content_hash`) for bootstrap/reconcile |
| `GET /notes/changes` | `NotesController.changes` | Notes-only seq feed |
| `GET /attachments/changes` | `AttachmentsController.changes` | Attachments-only seq feed |
| `POST /notes/batch`, `/notes/batch-delete`, `/notes/batch-move`, `/folders/batch-*`, `/attachments/batch-*` | bulk | Idempotent bulk ops (require `X-Idempotency-Key`, enforced by the `IdempotencyKey` plug) |

## Unified change-log pull (`GET /sync/changes`)
1. Decode `cursor` param → `{after_seq, after_id}` (absent = `{0, nil}` first pull; malformed → **400 `invalid_cursor`**).
2. If `after_seq < retention_floor(vault)` → **410 `history_expired`** (forces a manifest re-sync; floor is 0 until compaction ships).
3. Fetch **`limit + 1`** from EACH feed (`Notes.list_changes_by_seq`, `Attachments.list_changes_by_seq`) — the `+1` probe lets the merge detect "more exist".
4. Tag each row `type: "note" | "attachment"`, merge-sort by `{seq, id}`, trim to `limit`, compute `next_cursor` (from the last kept row) + `has_more`.
5. **Pull-carries-ack:** record the *incoming* cursor's `after_seq` as the device watermark (no-op if no `X-Device-Id`).

Params: `limit` (clamped to the per-feed 500 ceiling — a larger limit could skip rows past `next_cursor`), `fields` (note projection: `meta` vs full content), `X-Device-Id` (watermark identity).
Response: `{ changes: [...], next_cursor, has_more }`.

## Device cursors (`Engram.Sync.DeviceCursor`, table `vault_device_cursors`)
Composite PK `(vault_id, device_id)`, `last_seq`, `last_seen_at`. It is the **GC/eviction record**, NOT the pagination source — clients hold their own position. `Sync.record_cursor/4` is monotonic (`GREATEST`), so a lagging/out-of-order pull never regresses the watermark. Will drive history compaction (PR D): the min `last_seq` across active devices is the safe retention floor.

## Manifest (`GET /sync/manifest`)
Full snapshot for first-sync + drift reconciliation: projects ONLY path-ciphertext + nonce + `content_hash` (not `content_ciphertext` — a 10k-note vault would OOM BEAM otherwise), decrypts paths server-side, sorts. A user with no DEK (zero writes) short-circuits to an empty manifest.

## Realtime channel (`EngramWeb.SyncChannel`)
Topic `sync:{user_id}:{vault_id}` (join asserts the user owns both). Client→Server: `push_note`, `delete_note`, `rename_note`, `pull_changes`. Server→Client: `note_changed` (via `broadcast_from` — excludes the pushing socket to halve its bandwidth on bulk sync). Presence tracked. Writes during a DEK rotation are gated by `RotationGate`. **The channel is a live nudge, not the source of truth — catch-up always goes through the seq-ordered pull.** See `channel-event-contract.md` for the event payloads.

## Key modules
- `lib/engram/sync.ex` — cursor codec + `record_cursor` + `retention_floor`
- `lib/engram/sync/device_cursor.ex` — the watermark schema
- `lib/engram_web/controllers/sync_controller.ex` — `changes` (unified) + `manifest`
- `lib/engram/notes.ex` / `attachments.ex` — `list_changes_by_seq/4` (the per-feed queries) + seq stamping on write
- `lib/engram/vaults.ex` — `next_seq!/1` (the seq source)
- `lib/engram_web/channels/sync_channel.ex` — realtime

## Gotchas
- **`seq` is per-vault, not global** — never compare seqs across vaults; the cursor is only meaningful within its vault.
- **The cursor is client-held.** The server's `vault_device_cursors` row is for GC, not for resuming a client — never paginate from it.
- **`limit` MUST stay ≤ 500.** Each feed hard-caps at 500; a larger limit + the `+1`-probe trim logic would silently skip in-range rows past `next_cursor`.
- **410 `history_expired`** (once compaction lands) means "your cursor predates retention" → client must re-bootstrap from `/sync/manifest`, not just retry the pull.
- Notes vs attachments are separate feeds merged at the controller — a note and attachment can never share a seq (both draw from `next_seq!`), which is what makes the merge a total order.

## References
- `channel-event-contract.md` — WS event payloads
- `b2-cursor-pull-e2e-triage.md` — the cursor-pull e2e bring-up triage
- `../engram-workspace/docs/api-contract.md` — REST/WS endpoint contract
- plugin `docs/internals.md` — the client side (`syncCursor`/`syncState`, `getSyncChanges`, manifest bootstrap)
- code: `lib/engram/sync.ex`, `sync_controller.ex`, `sync_channel.ex`, `vaults.ex:113`
