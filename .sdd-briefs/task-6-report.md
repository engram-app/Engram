# Task 6 report: Rename folder (web to web)

## What I implemented

Appended the rename-folder test verbatim from the brief into
`frontend/e2e/tree-ops-sync.spec.ts`, inside the existing `describe` block,
after the move-note test. No new imports were needed: `createFolder`,
`expandFolder`, `commitRename`, `openContextMenu`, `pickAction`, `row` were
already imported by Tasks 1-5.

Found and fixed a real root-cause bug in the backend folder-rename cascade
(see below).

## TDD evidence

### RED

```
cd frontend && bunx playwright test --project=local tree-ops-sync -g "rename folder"
```

Failed at the final content-sync assertion:

```
1) [local] › e2e/tree-ops-sync.spec.ts:187:6 › web tree ops sync (web to web) › rename folder propagates to a second tab, child re-paths

    Error: expect(locator).toContainText(expected) failed

    Locator: locator('.cm-content')
    Expected substring: "EDIT-AFTER-FOLDER-RENAME"
    Received string:    ""
    Timeout: 10000ms

      231 | 		await pageA.keyboard.press("Control+End");
      232 | 		await pageA.keyboard.type(" EDIT-AFTER-FOLDER-RENAME");
    > 233 | 		await expect(edB).toContainText("EDIT-AFTER-FOLDER-RENAME", { timeout: 10_000 });

  1 failed
```

All the tree-convergence assertions before that line passed (NewName visible
in both tabs, OldName gone, child reachable under NewName in tab B) — only the
CRDT content-channel assertion failed, isolating the bug to the note's live
content channel, not the folder tree.

### GREEN

```
cd frontend && bunx playwright test --project=local tree-ops-sync -g "rename folder"
```

```
1 passed (27.8s)
```

Re-ran isolated a second time to confirm it wasn't a fluke: `1 passed (29.8s)`.

Also ran the whole spec file together (`bunx playwright test --project=local
tree-ops-sync.spec.ts`): rename-folder + smoke + rename-note + delete-note all
passed. move-note flaked independently in the full 5-test parallel run
(`toHaveCount(0)` on the tree row, unrelated mutation path — `useMoveNote`,
not `useRenameFolder`); re-ran move-note alone and it passed clean
(`1 passed (27.7s)`), confirming pre-existing parallel-run contention in this
suite, not a regression from this change.

## Real bug found + fixed

**File:** `lib/engram/notes.ex`, function `do_rename_folder/5` (the broadcast
loop around line 2876, originally lines 2885-2886).

**Root cause:** the per-descendant "upsert" broadcast after a folder rename
called the 4-arity `broadcast_change/4` clause (`event_type, path` only —
`defp broadcast_change(user_id, vault_id, event_type, path)` at line 3346),
which emits a `note_changed` payload with **no `id` field**. Compare to
`do_rename_note/6` (single-note rename, line 1048), which correctly calls the
6-arity clause (`broadcast_change(user.id, vault.id, "upsert", note.path,
decrypted)`) that includes `"id" => note.id` in the payload.

The frontend's `handleNoteChanged` (`frontend/src/api/channel.ts:194`) only
invalidates the id-keyed `["note", vaultId, id]` cache when `payload.id !==
undefined`. Since `useNote(id)` (the query the CRDT-binding effect in
`note-page.tsx` depends on) is keyed strictly by id (the legacy path-keyed
cache is dead weight per the code comment), a missing `id` meant tab B's
`useNote(childId)` cache never invalidated after a folder rename. `note-page.tsx`'s
effect (`useEffect(..., [path])`) never saw a new `path`, so it never
`closeDoc`d the pre-rename CRDT doc and `openDoc`d the post-rename one — tab
B's editor stayed bound to the stale doc/topic and silently missed every
subsequent Y update broadcast under the new `doc_id`.

**Fix:** pass the actual (id-bearing) `%Note{}` struct through the 6-arity
clause instead, with `path`/`folder` updated to the post-rename values:

```elixir
:ok = broadcast_change(user.id, vault.id, "delete", old_note_path)

:ok =
  broadcast_change(
    user.id,
    vault.id,
    "upsert",
    new_path,
    %{note | path: new_path, folder: new_note_folder}
  )
```

This mirrors what `do_rename_note/6` already does for a single-note rename.
The `folder_delete` cascade path (`do_delete_folders/2`) only ever broadcasts
`"delete"` (arity-4, no `id` needed — deletes are id-agnostic on the frontend)
so it was not affected and needed no change.

## Files changed

- `frontend/e2e/tree-ops-sync.spec.ts` — appended the rename-folder test
  verbatim (including the content-sync block).
- `lib/engram/notes.ex` — `do_rename_folder/5` broadcast fix (root-cause,
  described above).

## Self-review

- Diffed the test body against the brief line by line: matches verbatim,
  including the "Content sync must survive the folder rename" block with
  `edA`/`edB`, `Control+End`, ` EDIT-AFTER-FOLDER-RENAME`, and the
  `toContainText` assertion — the block earlier tasks slipped on is present.
- No em dashes introduced in test or Elixir comments (checked both diffs).
- `./node_modules/.bin/biome check e2e/tree-ops-sync.spec.ts` — clean, no
  fixes needed.
- `mix format --check-formatted lib/engram/notes.ex` — clean.
- `mix credo --strict lib/engram/notes.ex` — no issues.
- No version bump touched (package.json / mix.exs unchanged).
- Did not touch `playwright.config.ts` (already wired per the task context).

## Concerns

- `move note propagates to a second tab` flaked once during a 5-test parallel
  run in this session (unrelated mutation path, passed clean standalone both
  before and after my change) — pre-existing suite flakiness under
  concurrency, not something this task's diff touches or should paper over.
  Flagging per "pre-existing failing tests are still your problem," but the
  fix is out of scope for a folder-rename task and no assertion/timeout was
  weakened to hide it.
- The `do_rename_folder` fix changes broadcast payload shape (adds `id`) for
  every descendant of a renamed folder in production too — this is a genuine
  behavior improvement (fixes the same silent CRDT-rebind gap for any real
  multi-tab user doing a folder rename), not test-only scaffolding.

## Fix: backend broadcast regression test

Added `test/engram/notes_broadcast_test.exs` describe block
`"rename_folder/4 cascade broadcast"`: creates a note under `Old/`, subscribes
to `sync:#{user.id}:#{vault.id}`, renames `Old` to `New`, then asserts the
cascade emits a `"delete"` `note_changed` event followed by an `"upsert"`
`note_changed` event whose payload carries `"id" == child.id` and
`"path" == "New/Child.md"`. This is the fast backend regression for the
`do_rename_folder/5` fix (id-less 4-arity `broadcast_change` swapped for the
6-arity id-bearing clause), asserting real PubSub broadcast payloads (no
mocks) rather than relying solely on the e2e web-to-web test.

Command run:
```
mix format test/engram/notes_broadcast_test.exs && mix test test/engram/notes_broadcast_test.exs
```

Full pass output (final lines):
```
Running ExUnit with seed: 467254, max_cases: 20
Excluding tags: [:qdrant_integration, :cluster, :integration]

...
Finished in 1.1 seconds (1.1s async, 0.00s sync)
3 tests, 0 failures
```
