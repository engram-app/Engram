# Decoupling CRDT room creation from writes

**Date:** 2026-08-19 (rev 2, after adversarial review)
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
   affect the converged result.
3. **Fan-out is already vault-channel based, not room-observer based.** The
   code says so directly: *"Relay's `document.updated` model... what lets an
   IDLE note (one the client never STEP1-enrolled) converge."*

`CrdtRegistry.terminate_room/1` confirms the model independently: it brutally
kills rooms and documents why that is safe, *"Nothing is lost: every room
update is already in the durable tail-log."*

Therefore: **a room is a performance cache for hot notes, not a correctness
requirement.**

### What that realisation does NOT license

Rev 1 of this spec concluded from the above that concurrent writers are safe by
construction and told reviewers not to add a lock. **That was wrong**, and the
adversarial review caught it. Commutativity makes append-versus-append safe. It
says nothing about the three mechanisms below, each of which silently assumes
the room is the *sole writer*. Removing an actor removes guarantees nobody
wrote down, which is the same failure mode that produced four separate defects
during #1424.

Those assumptions are enumerated as Phase 0 and are **hard prerequisites**, not
follow-ups.

---

## Phase 0: remove the sole-writer assumptions

Nothing in Phase 1 may land before all three of these.

### 0a. Watermark pruning must go (CRITICAL, silent data loss)

`crdt_checkpoint_timer.ex:447` passes only `captured_version`, no `:prune_ids`,
so every live-room checkpoint takes the watermark path:

```elixir
defp prune_tail(note_id, {:watermark, watermark}) do
  CrdtUpdateLog |> where([l], l.note_id == ^note_id and l.inserted_at <= ^watermark) |> Repo.delete_all()
end
```

This deletes every row at or below the watermark **regardless of whether the
room's doc folded it**. That is safe only because a room is currently the sole
writer, so its doc always reflects every tail row in existence. The in-code
comment protects rows inserted *after* watermark capture; nothing protects a
row inserted *before* capture but *after* the room's doc last incorporated the
tail. Today that window is empty by construction.

The Phase 1 routing rule creates it, because lookup-then-append is not atomic:

1. No room, so client A's `:edit` routes detached.
2. Client B sends STEP1. Room starts, binds, `replay_tail` runs. A's row has not
   committed, so the room's doc misses it.
3. A's append commits. Row R is in the tail; the room's doc does not contain it.
4. The checkpoint timer fires. It captures a watermark after R, snapshots the
   stale doc, and prunes `<= wm`, **deleting R**.

R is then absent from both the snapshot and the tail. Permanent silent loss.
The fanout delivered R to clients connected at that instant, so it looks
correct live and is gone from server state forever. This is the #285 class that
`:prune_ids` was introduced to fix, reopened through a different door.

**Change:** every checkpoint uses exact `:prune_ids`. Delete the watermark
branch rather than leaving it available, so no future caller can reintroduce
the assumption. `replay_tail/3` already returns the folded ids
(`@spec ... :: [Ecto.UUID.t()]`) and `update_v1` knows the row it inserted, so
the room can accumulate folded ids cheaply.

**Test:** a row appended by a non-room writer between a room's bind and its
checkpoint survives the checkpoint and is present after the next bind.

### 0b. Head markers must never be computed from a partial view (CRITICAL)

`head_marker/1` is `sha256(state vector)`, and the client compares the value.
From `sync.ts:2107`: it gates the *convergence cost gate*
(`getCrdtHead === serverHead` -> skip).

With a room, every fanout head descends from one authoritative doc, so heads
form a total order that only advances. Two concurrent detached writes compute
their markers from independent transient docs, each seeing a different subset,
producing sibling heads that reflect no state any party actually holds. A client
can store a head it never reached and have the gate skip convergence while it is
genuinely behind. That is the deaf-note class in
`deaf-livebound-base-loss-diagnosis.md`: catch-up faking convergence.

**Change:** the detached path does not send a computed head marker. It sends an
explicit unknown that can never satisfy the equality gate, so the client
converges normally. A head marker exists only as a cost optimisation, so
degrading it to "unknown" costs one handshake and never costs correctness.

The governing rule, and the one rev 1 violated: **never emit a claim of
convergence you cannot prove.** Same discipline as "a no-op must never report
as work."

**Test:** two concurrent detached writes to one note leave a client that
applied both with a head that does not equal the server's, so the cost gate
does not skip.

### 0c. Compaction is a correctness and abuse boundary, not tuning

Rev 1 argued compaction is self-limiting because "hot notes have rooms". That
relies on the plugin's client-side `isLiveBound`, which the server does not
control and must not assume.

A client that repeatedly edits a note without enrolling forces the detached
path every time. Each write decrypts the full snapshot and replays a growing
tail: O(n²) in tail depth, plus a full-snapshot decrypt per write on large
notes. The `:edit` rate lane bounds frames per second, not cost per frame, so
it does not bound this.

**Change:** the compaction trigger is server-side and mandatory, on folded row
count, and is not conditional on any client behaviour. Threshold is
config-driven with a default, and firing is logged so a bad value is visible
rather than silent.

---

## Phase 1: the routing rule

In `handle_in("crdt_msg", ...)`, replace the unconditional `ensure_room/2`.
`frame_class_b64/1` already returns `:handshake` vs `:edit`, so the input
exists today and is discarded.

| frame | resolved room | action |
|---|---|---|
| `:handshake` (STEP1/STEP2) | any | `ensure_room` then relay (unchanged) |
| `:edit` | live pid | relay to room (unchanged) |
| `:edit` | none, or **dying pid** | **detached apply (new)** |

### Room resolution is not a boolean

Rev 1's table treated "room exists" as binary. It is not.
`CrdtRegistry.lookup/1` returns the raw `:global.whereis_name` result, and the
module header warns it *"can hand back a room that is mid-termination"*. Rooms
run `auto_exit: true` and stop when the last observer leaves, so termination is
routine rather than exotic. A frame relayed to a dying room is swallowed, which
is exactly why the drain exists (`cast` to a dead pid returns `:ok`).

`ensure_started/3` already carries bounded-retry discipline for this
(`@observe_attempts 5`, `@observe_retry_delay_ms 5`). The `:edit` route needs a
resolver with the same discipline that returns a **live** pid or nothing, and
falls through to detached rather than relaying into a terminating room.

### Detached apply

Reuses the machinery shipped in #1424, generalised from genesis to any update:

1. `fold_row_and_tail/4` in a short tenant transaction: read the note row's
   snapshot, `replay_tail/3` into a transient `%Yex.Doc{}`, return the doc plus
   the exact ids folded.
2. Apply the decoded update to the transient doc.
3. Append the update to `crdt_update_log` (identical to `update_v1`'s insert)
   and invalidate `crdt_head`.
4. `CrdtDeliver.fanout_idle/3`, carrying the **unknown** head marker per 0b.
5. Compact if the folded row count exceeds the Phase 0c threshold, passing
   exact `:prune_ids`.
6. Discard the doc.

### Fan-out is a correctness invariant, not a convenience

Rev 1 cited vault-channel fanout as *evidence* that rooms are caches, and filed
it as background. Once writes can bypass a room, that broadcast becomes the
only delivery path for a client whose room bound before the append. It is
therefore load-bearing and needs an explicit invariant and test.

#1424 already lost fanout once while removing a room, and device B wrote a
0-byte file (`e3b0c44298fc`, the SHA-256 of the empty string). Only the paired
e2e caught it.

### Cost profile

Detached writes are cheap when the doc is small or new (empty snapshot, empty
tail: the genesis case, already proven at 73% room reduction) and expensive
when the snapshot is large, because materialisation decrypts it. A room
amortises that across many edits.

Under this rule rooms are created only by STEP1, which happens when a note is
opened in an editor, so hot notes amortise and cold notes pay once. This is a
useful property but, per 0c, it is **not** relied on for boundedness.

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
  `rescue` plus `catch :exit`. Reject the frame; never append a row that cannot
  be replayed.
- **A room starts between resolution and append.** Safe once 0a lands, and only
  then: both paths append to the same tail, updates commute, and the room's
  next materialisation replays the appended row without any checkpoint pruning
  it unfolded. Deliberately not locked. #1424 added an advisory lock for the
  analogous genesis race, measured 7.5-101ms hold, and removed it as worse than
  the bug because `DynamicSupervisor` runs `init/1` inline and stalled room
  starts node-wide. **This reasoning is valid only with 0a in place.**
- **Compaction racing an append.** Handled by `:prune_ids`: a row appended
  mid-compaction is not in the folded set and survives.

## Testing

Unit:

- an `:edit` frame for a note with no room appends a tail row and starts no
  room (assert the `room_start` counter, not residency, which is sampled and
  lags)
- an `:edit` frame for a note with a live room still routes to the room
- an `:edit` frame whose resolved pid is mid-termination falls through to
  detached rather than relaying into it
- a `:handshake` frame still creates a room
- **0a:** a row appended between a room's bind and its checkpoint survives
- **0b:** concurrent detached writes leave the client's head unequal to the
  server's, so the cost gate does not skip
- **0c:** compaction fires on the row-count threshold with no client signal
- two concurrent detached applies to one note both survive and converge
- detached apply fans out `note_yjs_update`

E2E, because this class is only ever caught there:

- bulk import of N notes creates zero rooms and every note's content lands on a
  second device (guards the #1424 fan-out regression)
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
  lands and the labelled counter shows what remains.
- **Awareness and presence.** Untouched.
- **Plugin changes.** None required. `wiring.ts:514` `reEnrollUnsent` enrolling
  without an `isLiveBound` gate is a real latent bug found during the same
  investigation, but it is independent and belongs in its own issue.

## Open question for implementation

The Phase 0c threshold needs a number, picked from measured replay cost against
real tail depths rather than guessed.

## Review history

Rev 1 was reviewed adversarially and did not survive. Four of its claims were
wrong or unsafe: sole-writership (0a), head-marker validity (0b), compaction as
tuning (0c), and room resolution as a boolean (Phase 1). The diagnosis was
unaffected; every defect was in the remedy. Recorded here because the same
class of error, removing an actor and inheriting its unwritten guarantees,
produced four defects in #1424 and then produced four more in the spec written
to fix it.
