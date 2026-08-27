# Context Doc: `crdt_create` is the web app's rename, so it must claim

_Last verified: 2026-08-17 (Engram #1400, fixed on the #1399 branch)_

## Status
Fixed. `genesis_crdt_note/5` now claims before the row transaction.

## What This Is

`crdt_create` reads like a create. It is also **the web app's only rename and
move path**, and that is not obvious from either side of the wire:

- `frontend/src/api/queries.ts` — `useRenameNote` calls `crdtCreateNote(id, new_path)`,
  commented *"Replaces POST /notes/rename"*.
- `frontend/src/viewer/folder-tree.tsx:147` — *"A CRDT move = crdt_create per id
  at its NEW path"*.

Server side it lands in `Notes.genesis_crdt_note/5` → `genesis_relocate_live/6`
→ `move_note/5` (Phase E2, "rename-as-move"). That chain moved the row and
claimed nothing in `filemeta_v0`.

## Why that was a latent data-loss bug

`filemeta_v0` is the authority for paths; `ProjectVaultIndex` derives
`notes.path_*` **from** it, and it *"walks the INDEX ENTRIES and corrects the row
each one names"*. So:

1. A client claims `note → A.md`.
2. The user renames it to `B.md` in the web app. Row moves; the entry still says `A.md`.
3. The index room checkpoints, which enqueues `ProjectVaultIndex`.
4. Projection reads the entry and repaths the row **back to `A.md`**.

The rename silently reverts — and because projection re-encrypts the path,
rewrites `path_hmac`, repaths Qdrant and enqueues link rewrites, it is a full
write, not a display artifact.

`identity.ex` already named this exact failure: *"a rename that moves and a claim
that does not gets REVERTED by the next projection run."* `claim_rename/5` was
built to prevent it on the REST path. The CRDT leg simply never got the same
treatment, and stayed invisible because **no shipped client wrote the index** —
until Engram-obsidian#362.

## The fix, and why it is deliberately narrow

`claim_crdt_relocate/5` claims **only** a live id moving to a free path.

**Claiming too eagerly is worse than the bug.** A claim is durable and cannot be
rolled back, so a claim for an operation that then does not happen makes the path
*permanently unclaimable* — every later claim on it is refused even though the
rows are free, and if the row holding it is ever deleted, projection performs the
rename the API rejected. Hence three exclusions:

| Case | Claim? | Why |
|---|---|---|
| Live id → free path | **yes** | this is the rename |
| First-time create | no | projection never acts on absence, so an unclaimed new note is benign |
| `classify_by_id` → `:taken` | no | genesis **re-mints a fresh id**, so a claim under the client's id names a row that never exists |
| Target occupied | no | the relocate rejects with `:id_conflict`; the claim would outlive the rejection |

Two other rules inherited from `claim_rename/5`:

- **Claim BEFORE the row transaction.** `Identity.apply_targets/4` calls
  `warn_if_in_transaction/3` — a claim inside a transaction has *"durability
  not guaranteed"*, because the tail-log append rolls back with the transaction
  while the caller treats the claim as committed. Threading the claim through
  the existing `with` head keeps it outside without re-indenting the body.
- **The row check is load-bearing, not redundant.** `Identity.claim/3` sees only
  collisions recorded IN THE MAP. In a vault whose notes predate any client
  writing it, essentially every collision is invisible there, so a target held by
  a ROW with no entry would sail straight through.

## Testing it

`test/engram/notes/identity_test.exs`, describe *"the crdt_create relocate leg
claims, like every other rename"*. Note the two negative tests are the important
ones — they pass trivially before the fix (nothing claimed at all) and only earn
their keep afterwards. Both are mutation-proven: dropping the occupied-target
guard, or claiming for creates, each turns exactly one red.

## The sibling legs, audited — both already correct

Worth writing down so nobody re-derives it. The obvious next suspicion is that
`crdt_delete` owes an `Identity.release` for the same reason a rename owes a
claim (a tombstoned note whose entry survives keeps a path reserved that nothing
can reuse). It does not:

- **`crdt_delete`** → `Notes.delete_note_by_id/4`, which is a thin wrapper that
  resolves the id and delegates to `delete_note/4` — the same function the REST
  path uses, and it already enqueues `Engram.Workers.ReleaseIndexEntries`.

The relocate leg was the only gap, because it is the only one that reached the
row through a path the REST equivalent does not share.

## Related
- `crdt-identity-authority.md` — why the map is the authority
- Engram #1400 (this bug), #1146 (the epic), Engram-obsidian#431 (the client that arms it)
