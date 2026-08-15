# The per-vault CRDT index room — shape, wire, and what it must NOT do yet

_Last verified: 2026-08-15_

**TL;DR:** `{:global, {:crdt_index, vault_id}}`, one `Y.Map` named `filemeta_v0`
(`path -> %{note_id, type, hash}`), riding the existing per-vault `crdt:` channel as
`crdt_index_msg`. **Deliberately inert** — nothing writes to it, nothing reads it back, and it must
**not** opt into the #1152 drain until #1151 gives it a checkpoint.

Shipped: PR TBD (`feat/crdt-index-room`). Refs #1150, #1146, #1152, engram-app/engram-workspace#167.

---

## Why the room exists

Identity today lives in three places that have to agree — `NoteIdMap` in the client, the REST
manifest, and the seq cursor. `docs/context/relay-pattern-audit.md` traces every drift incident to
that split, and lists the ~18 functions in `plugin/src/sync.ts` that exist only to keep them
agreeing. Relay has no such class because identity converges through the **same channel as
content**, as a `Y.Map` inside a synced doc. This room is that map.

The name `filemeta_v0` matches Relay's (`SyncStore.ts:20`) on purpose: the shape is the part of
their design that removes the drift class, and keeping the name makes the correspondence checkable
rather than folkloric.

## The trap: #1150 and #1152 combine badly

Draining a **note** room is lossless *only* because `terminate/2` → `CrdtPersistence.unbind/3`
checkpoints on the way out. The index room has **no persistence at all** until #1151
(`CrdtIndexPersistence.bind/3` is a no-op; `bind/3` is the only required callback —
`deps/y_ex/lib/protocols/shared_doc.ex:350`).

So giving the index room `idle_exit_ms` would exit it and **evaporate the entire index**. The drain
would be working perfectly — it just has nothing to save here. Nothing in #1152's own suite could
catch this, because from the drain's side the behaviour is identical.

**The index room therefore runs no `CrdtCheckpointTimer` and sets no `idle_exit_ms`.** Residency is
bounded the old way (`auto_exit` on last observer), which is adequate precisely because the room
holds nothing durable. Enabling the drain is a #1151 follow-up, not a #1150 knob.

`crdt_index_room_test.exs` pins this by inspecting what the room is **linked to** — a
`CrdtCheckpointTimer` links itself to its room, so its absence is the real invariant. An earlier
version of that test asserted over the `opts` the test itself passed in, which could never fail;
see "Testing notes" below.

## Wire

- **Event:** `crdt_index_msg`, `%{"b64" => …}` in both directions.
- **No `doc_id`.** The vault is implicit in the channel topic and there is exactly one index room
  per connection. A doc_id-addressable index room would be a second way to name the same thing —
  and worse, would let a client drive the index through the note path, bypassing `note_in_vault?`.
  Pinned by a test asserting `crdt_msg` with the vault id replies `note_not_found`.
- **Rate bucket: handshake, not edit.** Index sync is once-per-connect. Billing it to the edit
  budget would let it starve real edits — the shape behind the 2026-07-07 cross-file-overwrite
  incident.
- **Relay ordering.** `handle_info({:yjs, frame, room})` checks `index_room` FIRST, so an index
  room can never be mistaken for a note room whose pid was reused.
- **Monitor + cache eviction.** Same rationale as note rooms: a dead room left in the cache means
  every later frame casts into a corpse and returns `:ok` (a `sync_update` is a `GenServer.cast`).

## Reuse rather than duplication

`CrdtIndexRegistry` does **not** re-roll the auto-exit retry dance.
`CrdtRegistry.observe_with_retry/3` is already public and takes injected functions precisely so a
second room type can reuse it — `:global` can hand back a room that is mid-termination, and a plain
`observe/1` would exit the caller. That race is identical for both room types.

## Testing notes

Two tests in the first draft of this work were **vacuous**, both caught by asking "would this go
red if the implementation were wrong?":

- the no-drain test asserted over the `opts` the test passed in — its own input, not the
  implementation. Now inspects the room's links, and was mutation-tested (wire a timer in → red).
- the rate-bucket test used `assert_push`, but with the edit budget pinned to 1 the FIRST frame
  succeeds either way. Now asserts the REPLY of all three frames; mutation-tested by switching the
  handler to `check_rate(socket, :edit)` → red.

Both mutations were reverted after confirming the red. Treat any test that passes on first write
with suspicion, and prefer mutating the implementation over re-reading the test.

## Not in scope here (and why)

| | |
|---|---|
| checkpoint / projection to `notes` rows | #1151 — also what unblocks the drain |
| client adoption, `getManifest` removal | Engram-obsidian#362/#363 (`phase/contract`) |
| compaction | #1153 — entangled with the #958 checkpoint-union hazard |
| per-folder sharding | #1154 (p3) |

**#167 does not close until #363.** Everything before it is scaffolding, and the p0's original
trigger (316 notes not materialising in a prod first-sync) is still unrooted — the issue explicitly
warns against closing it on the back of that bug being solved some other way.
