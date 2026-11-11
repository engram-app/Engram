# Context Doc: `crdt_create` is the web app's rename, so it must claim

_Last verified: 2026-10-03 (Engram #1400)_

## Status
Fixed. `genesis_crdt_note/5` now claims before the row transaction.

## What This Is

`crdt_create` reads like a create. It is also **the web app's only rename and
move path**, and that is not obvious from either side of the wire:

- `frontend/src/api/queries.ts` — `useRenameNote` calls `crdtCreateNote(id, new_path)`,
  commented *"Replaces POST /notes/rename"*.
- `frontend/src/viewer/folder-tree.tsx`: *"A CRDT move = crdt_create per id
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
treatment, and stayed invisible because **no shipped client wrote the index**
until Engram-obsidian#362 (now shipped).

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
  while the caller treats the claim as committed. Since 2026-10-16 the row
  transaction classifies first and, only on the relocate leg, returns
  `{:claim_first, live}` before writing anything; `run_genesis/2` claims and
  re-runs it. Every create that claims nothing pays one classify, not two.
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

## The REST mirror image: a by-path EDIT is not a create (E7, 2026-11-10)

`POST /api/notes` finds its row by PATH only (`lookup_and_write/2`). A folder
rename repaths rows in place, so the old path then holds no live row and no
tombstone. A client still editing at the old path missed, fell through
`upsert_pathless/1` to `insert_new_note`, and got a 200 with a NEW id: a
duplicate note, and the renamed-away folder reappeared. Pre-existing since at
least 0.78.1; found by the release C staging probe.

The client had sent `base_hash`, which means "I am editing the version I
read". `do_update_note` checks it only when a row exists. The fix is one
clause in `upsert_pathless/1`: no live row by path or id AND a `base_hash`
means `{:error, :stale_base}`, which REST renders as
`409 {conflict: true, reason: "stale_base"}` (the controller's
`conflict_reason/2`, shared with `recently_deleted` and `concurrent_edit`).
MCP `write_note` with `base_hash` already answered "re-read" on a miss via
`rmw_note/5`, and pops `base_hash` before `upsert_note`, so it is unaffected.

What it does NOT cover: a stale by-path write WITHOUT `base_hash` still creates
a duplicate. Web/JWT writers need no base, and the plugin's REST fallback for
canvas and oversized notes sends neither id nor base. Only by-id REST writes
(S4/S5) close that.

One reason code moved: a `base_hash` write with no id at a path deleted seconds
ago, carrying the deleted content, used to answer `recently_deleted` (the check
lives in `insert_new_note`). It now answers `stale_base` first. Both mean "write
nothing, converge"; a client that only handles `recently_deleted` sees a
generic conflict.

What did not change:
- A write WITHOUT `base_hash` at a missing path still creates (that is a create).
- A `base_hash` write naming a TOMBSTONED id still resurrects it (the id-keyed
  rename); the guard sits below the id lookup.
- The plugin pushes with its `id`: a live row elsewhere is still `:id_collision`,
  and a tombstone still resurrects or answers `recently_deleted`. Only an
  offline-queue replay carrying an id the server never knew plus a stored
  `serverHash` now 409s; its conflict branch re-pushes with `force`, which sends
  no `base_hash` and creates as before.

Test: `test/engram_web/controllers/notes_controller_test.exs`, describe
"POST /notes with base_hash at a path renamed away", and the `upsert_note/3`
cases in `test/engram/notes_test.exs` (renamed-away path, tombstone at the path,
tombstoned id still resurrects, no-base control).

The durable fix is by-id REST writes, so an edit follows the note across renames.

## Related
- `crdt-identity-authority.md` — why the map is the authority
- Engram #1400 (this bug), #1146 (the epic), Engram-obsidian#431 (the client that arms it)
