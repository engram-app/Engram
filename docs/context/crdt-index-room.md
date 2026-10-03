# The per-vault CRDT index room: shape, wire, residency, projection

_Last verified: 2026-10-03_

**TL;DR:** `{:global, {:crdt_index, vault_id}}`, one `Y.Map` named `filemeta_v0`
(`path -> %{note_id, type, hash}`), riding the existing per-vault `crdt:` channel as
`crdt_index_msg`. **This map is AUTHORITATIVE for note paths** as of #1151 step 2 —
`Engram.Notes.Identity` is the only server-side writer, `Engram.Workers.ProjectVaultIndex`
reads it and derives the `notes.path_*` columns. Durability shipped in #1151 step 1, with a
per-update tail log in #1391; the idle drain is wired (#1487, see "Residency" below). See
`crdt-identity-authority.md` for the decision, and note that projection must NEVER claim
(`rename_note/5` takes `index: :skip` for it) or it feeds itself.

The plugin writes this map (SyncStore, Engram-obsidian#362/#431), so projection is live in
production. A client can claim a path before `crdt_create` is acked; if the create never lands,
the claim names a note that will never exist. `ProjectVaultIndex` releases such a claim once its
UUIDv7 mint time is older than an hour (`@stale_claim_grace_ms`, #1550,
`Engram.Workers.ReleaseIndexEntries`). A younger in-flight create is reported `unresolved`, not
released.

Shipped: PR #1383 (`feat/crdt-index-room`). Refs #1150, #1146, #1152, #1550,
engram-app/engram-workspace#167.

---

## Why the room exists

Identity lived in three places that had to agree: `NoteIdMap` in the client, the REST
manifest, and the seq cursor. `sync-pattern-audit.md` (this repo) traces every drift incident to
that split, and lists the ~18 functions in `plugin/src/sync.ts` that exist only to keep them
agreeing. The class disappears when identity converges through the **same channel as
content**, as a `Y.Map` inside a synced doc. This room is that map.

The name `filemeta_v0` is the wire contract shared with the client: a single flat map keyed by
path is the shape that removes the drift class, and pinning the name makes the correspondence
checkable rather than folkloric.

## Rule: a room may only drain if `unbind` checkpoints it

Draining a **note** room is lossless only because `terminate/2` → `CrdtPersistence.unbind/3`
checkpoints on the way out. At #1150 the index room had no persistence (`bind/3` was a no-op), so
an idle exit would have evaporated the whole index while the drain itself behaved perfectly.
Nothing in the drain's own suite could catch that. `CrdtIndexPersistence` now encrypts the doc into
`vault_index_states` on `unbind/3` and restores it on `bind/3`, plus the #1391 tail log.

## Wire

- **Event:** `crdt_index_msg`, `%{"b64" => …}` in both directions.
- **No `doc_id`.** The vault is implicit in the channel topic and there is exactly one index room
  per connection. A doc_id-addressable index room would be a second way to name the same thing —
  and worse, would let a client drive the index through the note path, bypassing `note_in_vault?`.
  Pinned by a test asserting `crdt_msg` with the vault id replies `note_not_found`.
- **Rate bucket: exactly the note path's.** `frame_class_b64/1` lanes by wire prefix, so a step1
  (and a small step2) rides the handshake lane and everything else — including every `sync_update`
  — rides the edit lane.

  Do not move all index traffic onto the handshake lane: a rename or create writes `filemeta_v0`
  as a `sync_update`, and relocating it only moves the starvation risk onto handshakes (the
  2026-07-07 cross-file-overwrite shape). Both lanes are pinned by tests.
- **Frame-relay ordering.** `handle_info({:yjs, frame, room})` checks `index_room` FIRST, so an index
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

- the timer test asserted over the `opts` the test passed in, its own input, not the
  implementation. It now inspects the room's links (a `CrdtCheckpointTimer` links itself to its
  room).
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
- **`auto_exit` + idle drain**: see "Residency".
- **Durability** — since #1151 an exiting room checkpoints, so a restart is no longer a wipe.

## Residency

`CrdtIndexDoc.start_link/1` starts a `CrdtCheckpointTimer` in `mode: :index`: keyed on
`vault_id`, LRU-tracked, and it **never checkpoints on a tick**. Only the room's own persistence
state knows which tail rows failed to replay, so a checkpoint not driven by `unbind/3` would prune
rows it never folded in. The drain does the exiting: observers let go, `auto_exit` fires,
`terminate/2` checkpoints.

The drain is ON unconditionally, with no off switch: this room is observed while ANY socket on the
vault is connected, so without it residency is session-length (#1149 measured 7.91 MB per 10k-note
vault). The interval resolves per-room opt → `CRDT_IDLE_EXIT_MS` → `@default_idle_exit_ms`
(300_000), never `nil`. Only index WRITES count as activity, so residency tracks mutation, not
connection count. `crdt_index_room_test.exs` "the room runs an INDEX-mode timer" pins it.

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

**The server accepts any writer, not just our client.** `crdt_channel.ex`'s `crdt_index_msg` handler relays any well-formed frame from any authenticated
socket on the vault, with no write gate. With projection live, a client that writes
`filemeta_v0["x.md"] = {note_id: …}` moves a real note — tombstone at the old path, Qdrant repath,
link rewrite, `delete` broadcast to every device. User-scoped, so not a tenancy hole, but it is a
real capability.

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
| `getManifest` removal | Engram-obsidian#363 (`phase/contract`, open) |
| compaction | #1153, entangled with the #958 checkpoint-union hazard |
| per-folder sharding | #1154 (p3) |

**#167 does not close until #363.** Everything before it is scaffolding, and the p0's original
trigger (316 notes not materialising in a prod first-sync) is still unrooted — the issue explicitly
warns against closing it on the back of that bug being solved some other way.
