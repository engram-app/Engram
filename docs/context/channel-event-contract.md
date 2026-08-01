# Context Doc: Phoenix Channel Event Contract

_Last verified: 2026-06-12 (sync protocol rev — dual-field broadcasts, notes.batch digest)_

## Status
Working — shipped. Updated for the 2026-06-12 sync protocol rev.

## What This Is
Complete specification for the Phoenix Channel-based real-time sync protocol between the Obsidian plugin / web SPA and the Engram server.

## Connection & Auth

```
WebSocket connect: wss://api.engram.page/socket/websocket?token=<api_key|jwt>
  → Socket.connect/3 validates Bearer token, assigns user_id
  → Client joins topic "sync:{user_id}:{vault_id}"
  → Channel.join/3 verifies user_id matches socket assignment + vault ownership
  → Presence tracks device (device_id from join params)
```

## Client → Server Events

None. All writes ride the `crdt:` channel (`crdt_msg`, `crdt_create`,
`crdt_create_batch`, `crdt_delete`, `crdt_catchup_since`). The legacy inbound
ops (`push_note`, `delete_note`, `rename_note`, `pull_changes`) had no caller
in any shipped client and were removed; a stray frame gets a
`{"reason": "gone", "use": "crdt channel"}` error reply (catch-all — the
channel never crashes on unknown frames, same posture as #862's stub).

## Server → Client Broadcasts

| Event | Payload | When | Purpose |
|-------|---------|------|---------|
| `note_changed` (upsert) | `{event_type: "upsert", id, path, vault_id, content, content_hash, title, folder, tags, mtime, updated_at, version}` | After a single-note upsert by ANY device | Real-time sync notification |
| `note_changed` (delete) | `{event_type: "delete", path, vault_id}` | After a delete/rename-away | Tombstone notification |
| `notes.batch` (upsert digest) | `{op: "upsert", vault_id, notes: [{event_type, id, path, title, folder, tags, mtime, version, updated_at, content_hash}]}` | ONE per `POST /api/notes/batch` call (replaces N `note_changed` events) | Bulk-push digest — metadata-only, never carries content |
| `notes.batch` (delete/move) | `{op: "delete"\|"move", ids, target_folder_id?}` | After batch delete / batch move | Batch-op notification |
| `vault_created` | `{vault_id, ...}` (topic `user:{user_id}`) | A vault is created (`Engram.Vaults.broadcast_vault_created/2`) | FTUX listener — onboarding waits for this alongside `vault_populated` |
| `vault_populated` | `{vault_id}` (topic `user:{user_id}`) | First note lands in an empty vault | FTUX listener |
| `presence_state` / `presence_diff` | Phoenix Presence shapes | Join / device change | Connected-device tracking |

## content_hash + the dual-field transition

`content_hash` is the server-side HMAC of the note content (keyed per-user —
**clients can never compute it locally**; they store the last seen value per
path and compare opaquely).

**Dual-field transition (one release):** `note_changed` upsert payloads carry
BOTH `content` and `content_hash` as of the 2026-06-12 protocol rev. `content`
is dropped the release after the plugin min-version floor covers the hash-only
handler. Self-host backends and plugins update on independent cadences — do
NOT drop `content` early. The `notes.batch` upsert digest is new in this rev
and was hash-only from day one.

Client behavior: compare the broadcast's `content_hash` to the stored
per-path serverHash → equal means no-op; differing means apply inline
`content` if present, else `GET /notes/{path}`.

## Echo Suppression

HTTP-originated pushes (REST single + batch) cannot identify a socket and use
plain `broadcast`; the plugin's pushing/recently-pushed sets plus the hash
compare make the echo a no-op. The 5-second echo cooldown remains as a safety
net. (Channel-originated `push_note` and its `broadcast_from/4` echo exclusion
died with the inbound ops — CRDT writes converge via Yjs merge, which is
idempotent under echo by construction.)

## References
- Sync Channel: `lib/engram_web/channels/sync_channel.ex`
- Broadcast construction: `lib/engram/notes.ex` (`broadcast_change/6`, `batch_upsert_side_effects/3`)
- SPA handlers: `frontend/src/api/channel.ts` (`handleNoteChanged`, `handleNotesBatch`)
- Plugin handlers: `Engram-obsidian/src/channel.ts` + `src/sync.ts` (`handleStreamEvent`)
- REST counterpart: workspace `docs/api-contract.md`
