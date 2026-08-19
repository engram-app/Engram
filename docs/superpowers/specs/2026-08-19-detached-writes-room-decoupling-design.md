# Decoupling CRDT room creation from writes

**Date:** 2026-08-19
**Repos:** `engram-app/engram` (backend), `engram-app/Engram-obsidian` (plugin, read-only impact)
**Epic:** #1146 (identity/content converge through different channels)
**Follows:** #1409 / #1424 (genesis seed detached), which piloted this pattern for note creation

> **Placement note:** this belongs in the Engram vault at
> `50 Engineering/_Superpowers Specs/`. It lives here temporarily because the
> engram MCP token was expired when it was written. Mirror it to the vault and
> delete this copy.

---

## Goal

Stop creating a CRDT room as a side effect of receiving a write. Room count
should scale with the number of notes open in editors, not with vault size.

## The problem

`handle_in("crdt_msg", ...)` calls `ensure_room/2` for every content frame. The
rule the system implements today is:

> a frame arrived, therefore spawn a stateful actor

Room creation is triggered by **traffic**, not by **demand for collaboration**.
A `SharedDoc` room is a live Y.Doc plus a checkpoint timer whose purpose is to
let multiple clients converge on one note in real time. A bulk import has no
collaboration in it: one writer, no concurrent peers. The correct number of
rooms for an import is zero.

### Evidence

Measured on staging 2026-08-19, importing a 1,516-note vault, using the
`[:engram, :crdt, :room_start]` counter added in #1424:

| | count | share |
|---|---|---|
| rooms created | 406 | 27% of notes |
| drained because they went idle | 166 | 41% |
| **force-evicted by the memory backstop** | **240** | **59%** |

Fifty-nine percent of the rooms created during a normal import were killed by
`CrdtRoomLru` before they ever went idle. A room that gets force-evicted before
it idles was created for work that never needed a session.

Residency behaviour from the same run (`cap=64`):

```
resident=135 backlog=55
resident=298 backlog=218
resident=316 backlog=236     <- peak
resident=300 -> 284 -> 268 -> 252 -> 236 -> 220 ...   <- exact -16 steps
```

The decay is perfectly linear at `@max_evictions_per_sweep 16` per 30s sweep.
The peak of 316 is not demand. It is the LRU unable to hold its own cap at 32
evictions/min. **The LRU is load-bearing during normal operation**, which means
it is not protecting against abuse, it is concealing a creation bug.

Raising the eviction rate is explicitly rejected as a fix. It changes the graph
and nothing else.

## The key realisation

`CrdtPersistence.update_v1/4` is the room's write path. It does exactly this:

```
encrypt(update) -> INSERT crdt_update_log -> invalidate crdt_head -> fan out note_yjs_update
```

Three properties follow, all already true in the current code:

1. **The tail log is append-only.** Nothing in the write path reads-then-writes
   shared state. Concurrent appends need no coordination.
2. **Y-CRDT updates are commutative and idempotent.** Apply order does not
   affect the converged result. The room's mailbox serialisation was never
   load-bearing for write correctness.
3. **Fan-out is already vault-channel based, not room-observer based.** The
   code says so directly: *"Relay's `document.updated` model... what lets an
   IDLE note (one the client never STEP1-enrolled) converge."*

Therefore: **a room is a performance cache for hot notes, not a correctness
requirement.** The snapshot on the note row is a compaction of the tail; the
tail is authoritative. `checkpoint/5` already takes `:prune_ids` precisely so a
compaction deletes only the rows it folded. (Omitting `:prune_ids` was the
data-loss bug found during #1424 review. That was the design signalling this
model.)

## Architecture

### Routing rule

In `handle_in("crdt_msg", ...)`, replace the unconditional `ensure_room/2` with
a three-way route. `frame_class_b64/1` already returns `:handshake` vs `:edit`,
and `:global.whereis_name({:crdt_doc, note_id})` is a non-creating lookup, so
both inputs exist today and are currently discarded.

| frame | room exists | action |
|---|---|---|
| `:handshake` (STEP1/STEP2) | either | `ensure_room` then relay (unchanged) |
| `:edit` | yes | relay to room (unchanged) |
| `:edit` | **no** | **detached apply (new)** |

The room, when one exists, remains the sole writer for that note. The route
never splits writers.

### Detached apply

Reuses the machinery shipped in #1424, generalised from genesis to any update:

1. `fold_row_and_tail/4` in a short tenant transaction: read the note row's
   snapshot, `replay_tail/3` into a transient `%Yex.Doc{}`, return the doc plus
   the exact `prune_ids` folded.
2. Apply the decoded update to the transient doc.
3. Append the update to `crdt_update_log` (identical to `update_v1`'s insert)
   and invalidate `crdt_head`.
4. `CrdtDeliver.fanout_idle/3` with `CrdtTransport.head_marker(doc)` from the
   transient doc.
5. Compact conditionally (see below).
6. Discard the doc.

### Compaction trigger

This is the one genuinely new decision. A room's checkpoint timer performed
compaction; without it the tail grows and replay slows.

Detached writes already pay full materialisation in step 1, so writing the
snapshot back is nearly free at that point. But paying a full encrypted
snapshot write per keystroke would be wasteful.

**Rule: compact when the folded tail exceeds a threshold, otherwise append
only.** Threshold on folded row count, config-driven with a default, since row
count is what drives replay cost.

This is self-limiting in practice. A note being typed into rapidly is a note
open in an editor, which means STEP1 ran, which means it has a room and never
reaches this path. Detached writes are inherently the low-frequency case.

### Cost profile (why the routing rule is also the right cache policy)

Detached writes are cheap when the doc is small or new (empty snapshot, empty
tail: the genesis case, already proven at 73% room reduction) and expensive
when the snapshot is large, because materialisation decrypts it.

A room amortises that cost across many edits. Under the new rule rooms are
created only by STEP1, and STEP1 happens when a note is opened in an editor.
So hot notes (open, edited repeatedly) get a room and amortise; cold notes
(bulk import, background sync, single remote edit) go detached and pay once.
The routing rule is therefore also a correct cache-admission policy, without
needing a separate heuristic.

## What this changes about eviction

`CrdtRoomLru` stops being load-bearing and becomes ordinary cache eviction:
always safe, never data-affecting, because evicting a room can no longer lose a
write. `max_resident` becomes a cache size that normal operation never reaches,
and the LRU retains value only as an abuse backstop.

`@max_evictions_per_sweep` stays as it is. It is only a problem while creation
is wrong.

## Error handling

- **Materialisation failure** (decrypt error, corrupt snapshot): reply with the
  existing error reason; do not append. The client's frame is held and
  re-delivered on rejoin, matching current `sendCrdt` refusal behaviour.
- **Apply failure** (malformed update): `apply_detached/1` already wraps
  `rescue` plus `catch :exit`. Reject the frame, do not append a row that
  cannot be replayed.
- **Race: a room starts between the lookup and the append.** Safe by
  construction. Both paths append to the same tail, updates are commutative,
  and the room's next materialisation replays the appended row. Explicitly
  *not* guarded, and the reasoning is recorded here so a later reader does not
  add a lock. (#1424 added an advisory lock for the analogous genesis race,
  measured 7.5-101ms hold, and it was removed as worse than the bug because
  `DynamicSupervisor` runs `init/1` inline and stalled room starts node-wide.)
- **Compaction racing an append.** Already handled: `:prune_ids` deletes only
  the folded ids, so a row appended mid-compaction survives.

## Testing

Unit (`test/engram_web/channels/`, `test/engram/notes/`):

- an `:edit` frame for a note with no room appends a tail row and starts no
  room (assert against the `room_start` counter, not residency, which is
  sampled and lags)
- an `:edit` frame for a note **with** a room still routes to the room
- a `:handshake` frame still creates a room
- two concurrent detached applies to one note both survive and converge
- compaction with `prune_ids` leaves a concurrently-appended row intact
- detached apply fans out `note_yjs_update` carrying a correct head marker

E2E (`e2e/tests/`), because this class is only ever caught there:

- bulk import of N notes creates zero rooms, and every note's content lands on
  a second device (guards the fan-out regression that #1424 hit, where device B
  received a 0-byte file)
- a note open in an editor on device A still converges live with device B

Regression fence: extend the existing room-count assertion to assert
`room_start_total == 0` across an import rather than sampling residency.

## Observability

Add a `source` label to `[:engram, :crdt, :room_start]` (`handshake` /
`create_batch` / other). The 2026-08-19 measurement could not attribute which
27% of notes still demanded a room because the counter is unlabelled. One label
settles it in a single import and verifies this change reaches zero.

## Non-goals

- **Detached STEP1 materialisation.** A handshake could also be served from a
  transient doc, making rooms a pure cache. Out of scope; revisit after this
  lands and the counter shows what remains.
- **Awareness and presence.** Untouched.
- **Plugin changes.** None required. The client cannot tell which path served
  its frame. `wiring.ts:514` `reEnrollUnsent` enrolling without an `isLiveBound`
  gate is a real latent bug found during the same investigation, but it is
  independent and belongs in its own issue.

## Open question for implementation

The compaction threshold default needs a number. Pick it from measured replay
cost against real tail depths rather than guessing, and log when it fires so a
badly chosen value is visible rather than silent.
