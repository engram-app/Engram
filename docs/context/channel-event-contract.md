# Context Doc: Phoenix Channel Event Contract

_Last verified: 2026-10-03_

## Status
Working, shipped.

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

None. All writes ride the `crdt:` channel (`crdt_msg`, `crdt_index_msg`,
`crdt_create`, `crdt_doc_state`, `crdt_doc_update`, `crdt_delete`,
`crdt_catchup_since`, `crdt_release`). A brand-new note's body rides
`crdt_create`'s optional `b64` genesis frame; the separate `crdt_create_batch`
frame was removed once the plugin retired it and the web app was the only
caller left, always sending a single entry. The legacy inbound
ops (`push_note`, `delete_note`, `rename_note`, `pull_changes`) had no caller
in any shipped client and were removed; a stray frame gets a
`{"reason": "gone", "use": "crdt channel"}` error reply (catch-all — the
channel never crashes on unknown frames, same posture as #862's stub).

`folder_op {op: "move"|"create", op_id, folder_id, parent_id, name}` on
`crdt:` (#2523 S4) exists only while the `folder_ops` runtime switch is on
(`ServiceConfig.override(:folder_ops, true)`, default off); the join replies
advertise it as `features.folder_ops`. Off, it gets the catch-all `bad_frame`
reply like any unknown frame. Both ops ack `{folder_id, seq}`; refusals are
`conflict`, `cycle`, `not_found`, `invalid_name` (plus `bad_frame`,
`rate_limited`). Create is find-or-create by (parent, name).
Owner: `Engram.Folders.Wire`. While on, the `crdt_create` reply also carries
the note's `folder_id`, and `GET /api/sync/manifest` carries `folders: [{id,
parent_id, name}]` plus a `folder_id` per note. The `crdt_create` reply and
`POST /api/folders` also carry `folders`: the folder's whole chain, root first.

`crdt_catchup_since` pages (the seq feed, `Notes.list_changes_by_seq/4`)
carry, on each LIVE note row, `folder_id` (nil at the root or when the folder
is unresolved) and `name` while the S3 name reads are on (#2523:
`Engram.Notes.Location.on?/0`, the `note_name` ledger done and the
`name_reads` override not false). The row's `path` stays its stored path,
except under a folder renamed without a cascade (`folders.notes_cascaded =
false`, written from S5 on), where it is the path that folder gives it.
Tombstones keep the path they were deleted at and carry neither field. A
client that ignores the two fields sees no change.

## Server → Client Broadcasts

| Event | Payload | When | Purpose |
|-------|---------|------|---------|
| `note_changed` (upsert) | `{event_type: "upsert", id, path, vault_id, content?, content_hash, title, folder, tags, mtime, updated_at, version, seq}` | After a single-note upsert by ANY device | Real-time sync notification |
| `note_changed` (delete) | `{event_type: "delete", path, vault_id, folder, id?, seq?, device_id?}` | After a delete/rename-away | Tombstone notification |

`seq` (additive, #609 / Engram-obsidian#642) is the committed seq of the write
the event announces: the upserted row's, or for a delete the tombstone's (a
rename-away delete carries the rename's seq). It equals what a later seq replay
returns for that row, so a client can fence a stale pre-delete upsert against a
delete exactly. Set in the one builder, `Notes.broadcast_change/6`; older
clients ignore it. Attachment events carry it too, from
`Attachments.broadcast_attachment/5` (upserts, move legs) and
`broadcast_delete/5` (tombstones).
| `note_changed` (attachment) | attachment upsert/delete payloads (`attachments.ex`) | After an attachment write | Same topic as notes |
| `folder_changed` | `{folder_id, parent_id, name, seq, deleted, device_id}` | After a folder rename, move or create from any surface, only while `folder_ops` is on | One event per folder; `device_id` for echo suppression (`Engram.Folders.Wire`) |
| `note_changed` (folder nudge) | `{event_type: "upsert", kind: "note", path}`, no id/content/hash/seq | With each `folder_changed` | Old plugins (1.36.0 to 1.39.2) answer it with a seq catch-up; `path` is the folder's new path, never ending in `.md`/`.canvas` |
| `notes.batch` (delete/move) | `{op: "delete"\|"move", ids, target_folder_id?}` | After batch delete / batch move | Batch-op notification |
| `vault_created` | `{vault_id, ...}` (topic `user:{user_id}`) | A vault is created (`Engram.Vaults.broadcast_vault_created/2`) | FTUX listener — onboarding waits for this alongside `vault_populated` |
| `vault_populated` | `{vault_id}` (topic `user:{user_id}`) | First note lands in an empty vault | FTUX listener |
| `presence_state` / `presence_diff` | Phoenix Presence shapes | Join / device change | Connected-device tracking |

## content_hash and `content`

`content_hash` is the server-side HMAC of the note content (keyed per-user —
**clients can never compute it locally**; they store the last seen value per
path and compare opaquely).

`note_changed` upserts carry `content` unless the row was meta-projected (e.g.
the folder-rename cascade), in which case the key is omitted, never `""`: an
empty string next to the real hash materialized 0-byte files (e2e test_34).
Clients must handle the hash-only shape.

Client behavior: compare the broadcast's `content_hash` to the stored
per-path serverHash → equal means no-op; differing means apply inline
`content` if present, else `GET /notes/{path}`.

## Echo Suppression

REST-originated writes have no socket pid for `broadcast_from` exclusion. The
plugin sends `X-Device-Id` on every REST call (`EngramWeb.OriginDevice`, #970),
and the server stamps it as `device_id` into `note_changed` delete events so the
originating device drops its own delete echo. Upsert echoes are absorbed by the
hash compare above. CRDT writes converge via Yjs merge, which is
idempotent under echo by construction.

Broadcasts from inside a multi-leg transaction (the folder cascade) go through
`Engram.Sync.Broadcast.deferred/1`, which buffers and flushes only on commit, so
a rollback never leaks phantom events.

## References
- Sync Channel: `lib/engram_web/channels/sync_channel.ex`
- Broadcast construction: `lib/engram/notes.ex` (`broadcast_change/6`), `lib/engram/sync/broadcast.ex`
- SPA handlers: `frontend/src/api/channel.ts` (`handleNoteChanged`, `handleNotesBatch`)
- Plugin handlers: `Engram-obsidian/src/channel.ts` + `src/sync.ts` (`handleStreamEvent`)
- REST counterpart: workspace `docs/api-contract.md`
