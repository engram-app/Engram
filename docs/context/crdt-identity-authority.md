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

So the map enforces uniqueness instead: **a claim onto a path a different note
already holds is refused**, and `rename_note/4` keeps returning
`{:error, :conflict}`. Uniqueness moved from the row to the authority, which is
the point — the map decides and the column follows.

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

`Engram.Notes.Identity` is the only writer of the map from server code.
`Engram.Workers.ProjectVaultIndex` is the only writer of the path columns. Each
has exactly one writer, which is the invariant the old design could not state.

**Projection must never claim.** It is deriving FROM the map; a claim there is a
feedback loop. `rename_note/4` takes `index: :skip` for that one caller, and
defaults to claiming so a new call site is fail-safe rather than fail-silent.

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
half-completing. The live-room path needs no gate; it only mutates memory, and
the room's own checkpoint is already gated.
