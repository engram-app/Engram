# Who owns "which note is at which path"

**Decision (2026-08-15): the `filemeta_v0` CRDT map owns it. The `notes.path_*`
columns are derived from it.** This supersedes #1146 decision 4, which chose a
dual-write.

## The problem it settles

Identity has lived in three places that must agree — the plugin's `NoteIdMap`,
the REST manifest, and the seq cursor. Every drift incident in this repo traces
to that split (`relay-pattern-audit.md`). #167 exists to collapse it to one.

Collapsing it raises a question the epic did not answer: the server ALSO changes
paths (web rename, MCP, folder rename, batch move). Two writers of identity, so
which one is right when they disagree?

## Why not dual-write

#1146 decision 4 said: rows stay authoritative, and every server-side path
change also writes the map. That is a dual-write, and the reason to reject it is
not style — it is which way a partial failure fails.

| | rows authoritative | map authoritative |
|---|---|---|
| server renames, map write lost | projection **reverts the user's rename** | cannot happen, map was written first |
| row write fails after map write | n/a | projection moves the row forward — converges on what was asked |

Dual-write's failure mode is silent data movement against intent. The map-first
failure mode is convergence toward intent. An adversarial review of the
dual-write implementation found three criticals and five important findings —
all eight in the write-back, none in projection. That distribution is the
argument: the seams between two writers are where the defects live.

## What it costs, and why we accepted it

A CRDT map op cannot join a Postgres transaction. That — not a migration window
— is the real reason dual-write was attractive.

The first cut of this decision accepted losing `{:error, :conflict}` on rename,
on the theory that the map would take any claim and CRDT merge would pick a
winner. **That does not work, and the reason is worth keeping:** the loser's
entry gets overwritten, leaving it unclaimed — and projection is
additive-corrective, so it never acts on a note the map does not mention. The
loser's ROW therefore never moves, never releases the row-level unique
constraint it holds, and the winner can never derive either. Both notes stuck,
permanently.

So a claim onto a path a different note already holds is refused, and
`rename_note/5` keeps returning `{:error, :conflict}`.

**But the map cannot enforce uniqueness on its own, and this is the single
easiest thing to get wrong here.** `Identity.claim/3` only sees collisions
recorded IN THE MAP, and until Engram-obsidian#362 no client writes it — so in
production almost every note has no entry and almost every real collision is
invisible to the claim. Callers therefore validate against the ROWS *before*
claiming (`claim_rename/5`, `validate_move_targets/3`, `claim_cascade/4`).

Skipping that row check is not "the same error, slightly later". The claim is
durable: the row write fails, the API reports a conflict, and the target path is
now permanently unclaimable by any note even though the rows are free — and if
the row holding it is ever deleted, projection performs the rename the API
rejected.

A refusal also applies to two entries in ONE claim naming the same path.
Displacing either way leaves the loser unclaimed, and since projection never
acts on absence its row never moves, never releases the unique constraint it
holds, and the winner can never derive either.

What is genuinely given up is narrower than feared:

* **A rename during a DEK rotation fails** rather than half-applying. The claim
  is the commit, so it cannot be best-effort.
* **Collisions arising from concurrent CLIENT merges** are not adjudicated —
  two devices can converge on a state where a note is unclaimed. Projection
  reports that as `unresolved` with a metric and a warning rather than
  preventing it, which is inherent to identity being a CRDT at all.

## The shape

1. A server-initiated path change **claims** it in the map. That is the commit.
2. Projection derives the `notes.path_*` columns from the map.
3. Everything that is not the CRDT — REST, search, MCP — reads the ordinary
   column, exactly as `CrdtCheckpoint` projects note CONTENT for the same reason.

`Engram.Notes.Identity` is the only writer of the map from server code, and
projection never writes the path columns DIRECTLY — it goes through
`rename_note/5`, which is this repo's one path rewriter. (`do_rename_note` and
the folder cascade write those columns too; the invariant is one rewriter, not
one caller.)

**Claim outside every transaction.** `Identity` reaches Postgres through
`Repo.with_tenant/2`, which JOINS an in-flight transaction — so a claim made
inside one has its snapshot write rolled back with the caller while a live-room
write survives. Same call, different durability, depending on whether the user
has a socket open.

No caller does this any more. `batch_move_folders/4` was the last, and it
dropped its batch-wide transaction rather than keep it: that transaction could
only revert ROWS, never the claims already committed, so it was not providing
batch atomicity — it was concealing that batch atomicity is impossible once a
claim is the commit. `Identity` still logs and counts `:in_transaction` as a
tripwire for future call sites.

**Projection must never claim.** It is deriving FROM the map; a claim there is a
feedback loop. `rename_note/5` takes `index: :skip` for that one caller, and
defaults to claiming so a new call site is fail-safe rather than fail-silent.

## Releasing is a job; claiming is not

A CLAIM is the commit, so it happens inline and before the row moves. A RELEASE
is cleanup after the row is already gone, and it runs through
`Engram.Workers.ReleaseIndexEntries`.

The difference is transactions. Both folder-delete paths — `Folders.delete/4`
and `Notes.batch_delete_folders/3` — wrap their cascade, and `Identity` reaches
Postgres via `Repo.with_tenant/2`, which JOINS an in-flight transaction.
Releasing inline from inside one breaks both ways: with no live room the
snapshot write rolls back with the caller, and WITH a live room the in-memory
write does NOT, so a later failing leg (the attachment leg is the real case)
brings the notes back with their entries gone — live notes the authority does
not mention, which projection can never repair because it never acts on absence.

Enqueueing fixes both by construction: the job rolls back with the transaction
that created it and only runs once the delete has committed. It also replaces a
discarded return value with a retry, which matters because a release refused
mid-rotation used to vanish silently and leave one permanent path reservation
per note.

## The tail log is what makes a claim durable

`vault_index_states` holds a snapshot written when a room EXITS. On its own that
meant every claim made since the last checkpoint lived only in room memory, so a
SIGKILL, a node loss or an ECS task replacement dropped committed identity — and
projection then converged the rows back to the superseded snapshot.

`vault_index_update_log` (#1391) closes it: every update is appended, replayed on
`bind/3` after the snapshot, and pruned by EXACT id when a checkpoint folds it
in. Never by a timestamp range — an update appended between the encode and the
delete is not in the snapshot, and a range prune would drop exactly the claim the
tail exists to protect.

Durability is reached when the ROOM processes its own update message, not when
`update_doc/2` returns; `handle_update_v1` is asynchronous. A kill inside that
window still loses the update, as it does for note rooms.

## Removals are id-keyed, never path-keyed

Removing an entry by deleting whatever sits at a path clobbers the entry of
whichever OTHER note legitimately holds it. Projection triggers exactly that
against itself on its chain case (note A moving to the path note B is vacating).
Match on `note_id`.

## A rotation blocks a rename, on purpose

Writing the snapshot encrypts, and `users.encrypted_dek` holds the OLD wrapped
dek until `final_flip` — so a write landing mid-rotation is unreadable once the
old key retires (#1341). Under map-authority the claim IS the commit, so it
cannot be "best effort": a rename during a DEK rotation fails loudly rather than
half-completing.

**Both routes are gated, before routing.** An earlier version gated only the
snapshot route, reasoning that "the live-room path needs no gate; it only
mutates memory, and the room's own checkpoint is already gated." The tail log
(#1391) falsified that. A room write becomes durable through `append_tail`,
which is gated; the checkpoint that was supposed to write the in-memory claim
"afterwards" is gated too and runs only at process death. So the ungated room
route returned `:ok`, wrote nothing anywhere, and lost the claim when the room
drained — with the caller's rename already committed against it. `RotationGate`
is therefore checked in `Identity.apply_targets/4` before it picks a route
(`route=gate phase=rotation` on `index_claim`).

One residual, deliberately not closed: a client writing `filemeta_v0` directly
over the channel bypasses `Identity` entirely, so its update reaches
`update_v1/4` and is dropped by `append_tail`'s gate (`phase=skipped_rotation`).
`SessionInvalidator.disconnect_user/1` drains sockets at the top of a rotation,
which narrows the window rather than eliminating it. It has no production
exposure until Engram-obsidian#362 makes a client write the map.
