# The per-vault CRDT index room — shape, wire, and what it must NOT do yet

_Last verified: 2026-08-15_

**TL;DR:** `{:global, {:crdt_index, vault_id}}`, one `Y.Map` named `filemeta_v0`
(`path -> %{note_id, type, hash}`), riding the existing per-vault `crdt:` channel as
`crdt_index_msg`. **Deliberately inert** — nothing writes to it, nothing reads it back, and it must
**not** opt into the #1152 drain until #1151 gives it a checkpoint.

Shipped: PR #1383 (`feat/crdt-index-room`). Refs #1150, #1146, #1152,
engram-app/engram-workspace#167.

---

## Why the room exists

Identity today lives in three places that have to agree — `NoteIdMap` in the client, the REST
manifest, and the seq cursor. `relay-pattern-audit.md` — in the **engram-workspace** repo, not this one
(`../engram-workspace/docs/context/relay-pattern-audit.md`) — traces every drift incident to
that split, and lists the ~18 functions in `plugin/src/sync.ts` that exist only to keep them
agreeing. Relay has no such class because identity converges through the **same channel as
content**, as a `Y.Map` inside a synced doc. This room is that map.

The name `filemeta_v0` matches Relay's (`SyncStore.ts:20`) on purpose: the shape is the part of
their design that removes the drift class, and keeping the name makes the correspondence checkable
rather than folkloric.

## The trap: #1150 and #1152 combined badly (now half-resolved)

Draining a **note** room is lossless *only* because `terminate/2` → `CrdtPersistence.unbind/3`
checkpoints on the way out. At #1150 the index room had **no persistence at all**
(`CrdtIndexPersistence.bind/3` was a no-op; `bind/3` is the only required callback —
`deps/y_ex/lib/protocols/shared_doc.ex:350`).

So giving the index room `idle_exit_ms` would have exited it and **evaporated the entire index**.
The drain would be working perfectly — it just had nothing to save here. Nothing in #1152's own
suite could catch that, because from the drain's side the behaviour is identical.

**#1151 step 1 fixes the missing half:** `CrdtIndexPersistence` now encrypts the doc into
`vault_index_states` on `unbind/3` and restores it on `bind/3`. See "Durability" below.

**The index room still runs no `CrdtCheckpointTimer` and sets no `idle_exit_ms`.** Opting in is a
deliberate, separate step (#1151 step 3) — durability makes the drain *safe*, it does not make it
*enabled*, and the two must not be conflated. Residency stays bounded the old way (`auto_exit` on
last observer).

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
- **Rate bucket: exactly the note path's.** `frame_class_b64/1` lanes by wire prefix, so a step1
  (and a small step2) rides the handshake lane and everything else — including every `sync_update`
  — rides the edit lane.

  An earlier version of this doc claimed index frames ride the handshake bucket outright, on the
  reasoning that index sync is once-per-connect. True of the handshake, false of the writes #1151
  adds: a rename or create writes `filemeta_v0`, which is a `sync_update`, which bills the user's
  edit budget. Whether that is right belongs to #1151, where those writes exist and their volume is
  known — moving ALL index traffic onto the handshake lane only relocates the starvation risk onto
  handshakes, which is the 2026-07-07 cross-file-overwrite shape. Both lanes are now pinned by
  tests so the decision is made against measured behaviour rather than a comment.
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

## What bounds the wire (there is no flag)

`crdt_index_msg` is open to any authenticated client on the vault's channel. No
feature flag — a gate that defers a risk is not the same as handling it, and a flag nobody flips
becomes permanent scaffolding.

What actually bounds it today:

- **Rate limit** — the same lanes as note frames (`frame_class_b64/1`): step1/small-step2 on the
  handshake budget, every `sync_update` on the edit budget.
- **5 MB decoded-frame ceiling** — `guard_frame/1`, shared with the note path.
- **`auto_exit`** — the room dies when the last socket on the vault disconnects.
- **Durability** — since #1151 an exiting room checkpoints, so a restart is no longer a wipe.

**The open residency item:** the index room runs no `CrdtCheckpointTimer`, so it gets neither the
#1152 idle drain nor LRU tracking, and `auto_exit` is session-length. A client that stays connected
can keep growing one doc. The timer is note-keyed (`note_id` threads through its state and its
`CrdtRoomLru.touch/3` call), so serving the index room means generalising it — that is the real
fix, and it is tracked rather than papered over with a flag.

## Projection onto the notes rows (#1151 step 2)

`Engram.Workers.ProjectVaultIndex` walks `filemeta_v0` and corrects the row each entry names.
This is what keeps REST, search and MCP working against a client-owned index — the server answers
"what is this note's path" from `notes.path_*`, never from Yjs state, exactly as `CrdtCheckpoint`
projects note CONTENT for the same reason.

**Additive-corrective, and it never acts on absence.** It walks the ENTRIES and fixes the rows they
name. It does NOT walk the notes asking whether the index still mentions them — a
reconcile-by-absence implementation would read an empty index as "this vault has no files" and
delete the vault. It follows that projection can never delete, and never touches a note the index
does not mention.

**Do not read that as "dormant".** An earlier draft argued the feature was inert because no client
writes the index yet. That is a claim about the client we ship, not about what the server accepts:
`crdt_channel.ex`'s `crdt_index_msg` handler relays any well-formed frame from any authenticated
socket on the vault, with no write gate. With projection live, a client that writes
`filemeta_v0["x.md"] = {note_id: …}` moves a real note — tombstone at the old path, Qdrant repath,
link rewrite, `delete` broadcast to every device. User-scoped, so not a tenancy hole, but it is a
real capability and it exists now. Inertness is a property of the WORKER (empty in, nothing out),
not of the system.

**Entries interact, so one pass is not enough.** A CHAIN (A wants the path B is vacating) converges
only if B is applied first — and that is not a coin flip: Erlang small maps iterate in TERM order,
so entries are visited sorted by target path, which for a chain is reliably the losing order. Small
vaults hit it every time. The worker therefore re-runs a pass that made progress AND still has
conflicts, up to 5 times. A SWAP (A wants B's path, B wants A's) cannot converge at all —
`rename_note/4` has no temp-path staging — so the loop halts on zero progress and reports it.

**A note claimed by two paths is dropped entirely.** Applying both moves it twice per pass, minting
two tombstones, two seq bumps, two Qdrant repaths and four broadcasts, on every checkpoint forever.
Projection cannot pick a winner and must not guess.

**What consistency it actually provides:** eventually consistent with the last PERSISTED snapshot.
The job can execute after a newer room has bound that snapshot and moved on, applying paths the
live room already superseded; the next checkpoint's run corrects it.

**Through `rename_note/4`, never the columns directly.** That function pre-checks the unique
`(user, vault, path_hmac)` constraint and answers `{:error, :conflict}` instead of crashing, and it
carries the Qdrant repath and link-rewrite legs. Writing `path_ciphertext`/`path_nonce`/`path_hmac`
here would make projection a second path writer against the exactly-one-rewriter invariant, and
would silently drop both legs.

**A worker, not the checkpoint.** `unbind/3` runs inside `terminate/2` against a shutdown budget; a
projection pass is N renames, each re-encrypting a path and repathing Qdrant. Doing that in a
terminating process during a deploy stampede loses the checkpoint AND the projection. The
checkpoint enqueues after the snapshot is durably written, so the worker can never read a snapshot
older than the doc that triggered it; per-vault `unique` collapses a storm into one job.

One entry's failure never stops the next — a single collision or stale id would otherwise strand
every entry behind it. Conflicts and unknown note_ids are logged and skipped: the index and the rows
disagreeing is not something projection resolves, because the client owns identity.

## Not in scope here (and why)

| | |
|---|---|
| enabling the idle drain + the wire flag | #1151 step 3 |
| client adoption, `getManifest` removal | Engram-obsidian#362/#363 (`phase/contract`) |
| compaction | #1153 — entangled with the #958 checkpoint-union hazard |
| per-folder sharding | #1154 (p3) |

**#167 does not close until #363.** Everything before it is scaffolding, and the p0's original
trigger (316 notes not materialising in a prod first-sync) is still unrooted — the issue explicitly
warns against closing it on the back of that bug being solved some other way.
