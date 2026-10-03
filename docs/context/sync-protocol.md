# Context Doc: Sync protocol (server-side)

_Last verified: 2026-10-03_

## Status
Working — ordered change-log / cursor-pull sync, shipped 2026-06 (backend PRs #628–#630, plugin #109). Compaction (history GC) is unbuilt; its planned watermark input (`vault_device_cursors`) was dropped as dead weight (see below), so a future compaction effort needs a new design, not a revival.

## What This Is
How the server lets a client (plugin or web SPA) converge a vault: a per-vault **ordered change-log** the client pulls forward over the `crdt:` socket with a client-held cursor, a **manifest** for first-sync/reconciliation, idempotent **bulk** ops, and a **WebSocket channel** for live nudges. The client holds its own position; the server is the ordered source of truth.

## Core model
- **`seq`**: a per-vault monotonic counter, `Engram.Vaults.next_seq!/1` (`vaults.ex`). Every note and attachment write stamps one. Notes and attachments draw from the same counter, but one write can stamp TWO rows at one seq (an attachment move, #614; a rename's tombstone + live row). Order by `{seq, id}`, never seq alone.
- **Cursor**: composite keyset `{cursor_seq, cursor_id}`, sent as plain payload fields on `crdt_catchup_since`. The client holds it; the server keeps no per-device position. A seq-only cursor skips the second row of a same-seq pair (#312). An invalid `cursor_id` degrades to seq-only; a malformed `cursor_seq` replies `bad_cursor`.

## Endpoints (all under `/api`, vault-scoped pipeline)
| Method/Path | Action | Purpose |
|---|---|---|
| `GET /sync/changes` | *(removed — REST-purge #1036)* | The unified ordered pull now travels ONLY over the `crdt:` socket topics; no REST route exists |
| `GET /sync/manifest` | `SyncController.manifest` | Full vault snapshot (path ciphertext + `content_hash`) for bootstrap/reconcile |
| `GET /notes/changes` | `NotesController.changes` | **Retired** — always 410 Gone (timestamp feed removed 2026-08; route kept so it's 410, not 404) |
| `GET /attachments/changes` | `AttachmentsController.changes` | **Retired** — always 410 Gone (same) |
| `POST /notes/batch-delete`, `/notes/batch-move`, `/folders/batch-*`, `/attachments/batch-*` | bulk | Idempotent bulk ops (require `X-Idempotency-Key`, enforced by the `IdempotencyKey` plug). `POST /notes/batch` itself was removed with the CRDT single-push path |

## Catch-up pull (`crdt_catchup_since`)
`CrdtChannel` → `Engram.Sync.merged_changes_page/7`:
1. Clamp `limit` to `@catchup_page_limit` (500, the per-feed cap; also the default).
2. Fetch `limit + 1` from EACH feed (`Notes.list_changes_by_seq/4`, `Attachments.list_changes_by_seq/4`). The `+1` probe detects "more exist". The notes feed also honors a byte budget (`max_bytes`).
3. Tag rows `:note | :attachment`, merge-sort by `{seq, id}`.
4. **Watermark clamp:** never emit past the last row of a feed that reported `has_more`. Emitting the other feed's higher seqs would advance the shared cursor past unfetched rows, and the client would skip them permanently.
5. Trim to `limit`, return `%{page, has_more, next}`.

The whole page build runs inside `Engram.Sync.PageGate.with_slot/1`, which bounds how many pages are in flight at once. It queues, never rejects: the client aborts its whole walk on a rejected fetch.

The device-cursor table (`vault_device_cursors`) was dropped 2026-09-08 (dead since #1036). Compaction is unbuilt; it will need a new watermark design against this socket path.

## Manifest (`GET /sync/manifest`)
Full snapshot for first-sync + drift reconciliation: projects ONLY path-ciphertext + nonce + `content_hash` (not `content_ciphertext` — a 10k-note vault would OOM BEAM otherwise), decrypts paths server-side, sorts. A user with no DEK (zero writes) short-circuits to an empty manifest.

## Realtime channel (`EngramWeb.SyncChannel`)
Topic `sync:{user_id}:{vault_id}` (join asserts the user owns both). Client→Server: none; all writes ride the `crdt:` channel and unknown frames get a `"gone"` error reply. Server→Client: `note_changed`, `notes.batch`, presence. **The channel is a live nudge, not the source of truth; catch-up always goes through `crdt_catchup_since`.** See `channel-event-contract.md` for the event payloads.

## Key modules
- `lib/engram/sync.ex`: `merged_changes_page/7`
- `lib/engram/sync/page_gate.ex`: in-flight page bound
- `lib/engram_web/channels/crdt_channel.ex`: `crdt_catchup_since` (cursor parse, limit clamp)
- `lib/engram_web/controllers/sync_controller.ex`: `manifest`
- `lib/engram/notes.ex` / `attachments.ex`: `list_changes_by_seq/4` + seq stamping on write
- `lib/engram/vaults.ex`: `next_seq!/1`
- `lib/engram_web/channels/sync_channel.ex` — realtime

## Gotchas
- **`seq` is per-vault, not global**: never compare seqs across vaults.
- **The cursor is client-held.** There is no server-side watermark record; never look for one to resume a client from.
- **`limit` MUST stay ≤ 500.** Each feed hard-caps at 500; a larger limit plus the `+1`-probe trim would silently skip in-range rows past `next`.
- **A rename emits TWO change rows**: a soft-deleted tombstone at the OLD path (fresh id) and the new-path upsert of the same note_id, at the same seq. Receivers must honor the delete and relocate by id even when echo suppression would skip the upsert. Swallowing either one resurrects the old path (Engram-obsidian#183).

## References
- `channel-event-contract.md` — WS event payloads
- `../engram-workspace/docs/api-contract.md` — REST/WS endpoint contract
- plugin `docs/internals.md`: the client side
