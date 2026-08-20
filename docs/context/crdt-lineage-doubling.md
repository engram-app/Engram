# CRDT lineage doubling — why the same edit must be encoded exactly once

_Last verified: 2026-08-18_

**Status:** two distinct mechanisms share this symptom.
1. **Dual-encoder** (the original) — root-caused + fixed 2026-07-02 (PR #846,
   deliver-out state-apply commit). Everything below through "Debugging recipe"
   describes this one.
2. **Flatten boundary** (#958) — OPEN as of 2026-08-18, reproduced. See
   "Second mechanism" at the end. Do not read the "fixed" above as covering it.

**Symptom class:** stored/live note content duplicates or char-interleaves under
rapid REST writes with a live room: `"Iteration 6"` + `"Iteration 7"` →
`"Iteration 67"`, `"Version 22"`, `"Version 233"`, full-body duplication.
E2E signatures: `test_49_cross_auth_sync` rapid_api_edits timeouts,
`test_78_hash_only_live_update` stale/mangled content, `test_10_rename_propagation`
timeouts. Historic flake #547 (note-live-update) is the same defect leaking through
timer checkpoints.

## The invariant

**One textual change may enter the Yjs universe through exactly one encoder.**
Yjs merges by op identity (client-id + clock), not by text. Two independently
produced op-sets that encode the *same* textual transition (e.g. `delete "1",
insert "2"`) are, to Yjs, two concurrent edits — union keeps both: `"22"`.
There is no server-side way to dedup them after the fact.

Verified minimally (two docs from one ancestor, both ingest the same text,
union the deltas): the text doubles. `Yex`/yrs is not doing anything wrong —
this is CRDT semantics.

## How we violated it (pre-fix architecture)

A REST/MCP write used to be encoded **twice**:

1. `Notes.maybe_merge_crdt/4` diffs the incoming plaintext against the snapshot
   on a fresh doc (fresh random client-id) → ops stored in `notes.crdt_state`.
2. `CrdtDeliver.deliver_out` → `ingest_plaintext(room_doc, content)` re-diffed
   the same plaintext against the room's text with the **room's** client-id →
   ops broadcast to observers AND appended to `crdt_update_log` by `update_v1`.

While REST merges ignored the tail (pre-#846), the stored row stayed clean and
only the ROOM doc was poisoned (surfacing as checkpoint clobbers = flake #547).
When #846's REST merge started replaying the tail (to preserve live typing in
the settle window), every REST write unioned encoding (2) from the tail with
encoding (1) already in the snapshot → deterministic doubling, cascading per
write.

## The fix

`CrdtDeliver.push_to_live_room` loads the note's **just-committed CRDT
snapshot** (post-commit read + decrypt) and `Yex.apply_update`s it onto the
room doc. Same lineage as the snapshot ⇒ the room's `update_v1` tail row is a
subset of stored state ⇒ tail replay onto the snapshot is idempotent. Plaintext
`ingest_plaintext` remains only as a degraded fallback when the state cannot be
loaded (missing row / decrypt failure).

Regression test: `crdt_channel_test.exs` "rapid REST writes with a live room".
The key to reproducing in a unit test: `SharedDoc.update_doc` is a **cast** —
you must synchronize on the room text converging AND the tail row landing
before issuing the next REST write, or the race window closes and the test
passes vacuously.

## Remaining single-encoder hazards (open)

- **Client-side echo:** the plugin's `sendUpdateRaw` forwards every local-origin
  ydoc update. A client that seeds its ydoc from disk while the server already
  has state (the `seedOnce` enroll race) injects a foreign-lineage full-text
  insert — same doubling, server cannot defend. Plugin-side "flatten lineage
  adoption" is the deferred fix (see PR #846 deferred list).
- Old `crdt_update_log` rows written by the pre-fix deliver are room-lineage
  encodings; they age out at the next checkpoint prune. No migration needed.

## Debugging recipe that cracked it

1. `gh run download <run>` → read the corrupted files in the vault artifacts
   (the interleave pattern itself tells you it's a lineage union, not a lost
   write).
2. Push a TEMP diag commit with `IO.puts` (NOT Logger — RedactFilter scrubs
   content) in `maybe_merge_crdt` (snapshot/tail/incoming texts),
   `CrdtDeliver.push_to_live_room` (room before/after), `update_v1` (bytes +
   doc text), `CrdtCheckpoint.checkpoint` (text), with a targeted run:
   commit message `[e2e: clerk/test_78 or test_49]` runs just those tests.
3. The MERGE-DIAG line `snapshot="…2" tail_doc="…22"` is the smoking gun shape.
4. Revert the diag commit before merge.

Caveat for local unit repro: the shared local test DB may carry migrations from
other branches (`mix ecto.reset` under MIX_ENV=test before trusting a big local
failure count), and `Repo.with_tenant` wraps returns in `{:ok, _}` (see
`with-tenant-return-wrapping.md`).

## Second mechanism: the flatten boundary (#958, OPEN)

_Added 2026-08-18._

Same symptom, different cause, and the #846 fix does not touch it. Reproduced
against `main` on 2026-08-18:

```
[1] after normal checkpoint:        "ALPHA"
[2] row flattened to fresh lineage; live doc still on old lineage
[3] after post-flatten checkpoint:  "ALPHA BETAALPHA"   <- expected "ALPHA BETA"
```

`maybe_flatten` (`crdt_checkpoint.ex`) is a RESET, not a merge: it replaces the
doc with a fresh single-client one. The call site persists only the flattened
`state` and **discards `_flat_doc`**, so the row moves to a new lineage while the
live room keeps running the old one. The next `union_with_row_state` folds two
disjoint lineages, and every old-lineage struct integrates as new content.

This does not violate the one-encoder invariant above. It violates the *other*
assumption the union rests on, stated in `do_checkpoint`'s own comment: "the
stored state is the same lineage deliver_out pushes, so the fold is idempotent."
After a flatten, it is not.

### Why there is no cheap fix (checked, 2026-08-18)

Do not re-derive these. Both obvious directions have holes:

**"Only flatten where it is safe."** There is no such site.

| Caller | Hole |
|---|---|
| `crdt_checkpoint_timer.ex` | live room keeps editing the old lineage |
| `crdt_persistence.ex` (unbind) | watermark prune lets tail rows written *during* the encode survive and replay onto the new lineage at next bind |
| `workers/checkpoint_note.ex` | overflow path from unbind; a room may have re-bound before the job runs |
| `crdt_channel.ex` (genesis) | already known to double, see below |

Plus a rebind race with no guard: a client binding a new room mid-unbind loads
the PRE-flatten state, then the unbind commits the flattened one. `snapshot_fence/2`
does not catch it, because a bind is not a write.

**"Detect disjoint lineage (client-id sets) and skip the union."** Cheap to
detect, but it **false-positives on genesis**: `crdt_channel.ex` states the
create-time checkpoint flattens to a fresh server lineage while the client frame
keeps its own, so a healthy new note legitimately presents disjoint lineages. A
blanket skip-or-abort would freeze them. That path is currently handled by
*avoidance* (do not re-checkpoint a `:skipped` create), not at the seam.

Skipping the union is also not free when detection is right: Phase 0 exists
because a room that missed a `deliver_out` is BEHIND committed writes, and
skipping there re-opens the 2026-07-07 data-loss class (MCP appends erased).

### Recommended direction

Record the lineage reset instead of inferring it. A lineage epoch on the row,
bumped on every flatten, lets the union distinguish "the live doc predates this
row's lineage" from "the live doc is merely behind" — the distinction every
proposed fix silently needs and none can currently make. Genesis then declares
its own reset rather than being special-cased at the call site.

Schema + protocol change, so it wants a design pass, and it should land before
#1151 mirrors this seam for the index room.

### Reproducing it

Do not commit the repro (it asserts buggy behaviour). Shape: checkpoint a doc
normally, then `CrdtBridge.flatten` the row state and write it back directly
(mirroring what `maybe_flatten` + `checkpoint_write` persist), then edit the
ORIGINAL doc and checkpoint again. The flatten ceilings (500KB AND 1000
client-ids) are not needed to demonstrate the mechanism.
