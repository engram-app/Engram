# Task 3: unbind Materializes Content (Full Checkpoint)

## Summary

**Status:** DONE

**Commit:** `6b3a1a11` (on branch `fix/crdt-sync-hardening`)

**Test Summary:** All 27 tests pass (crdt_persistence_test.exs + crdt_checkpoint_test.exs, seed=0)

## Implementation

### Changes Made

1. **Modified `lib/engram/notes/crdt_persistence.ex`:**
   - Replaced `unbind/3`'s body (37 lines) with a single-line delegation to `CrdtCheckpoint.checkpoint/4`
   - Updated function signature to extract `vault_id` from state (needed for checkpoint call)
   - Updated docstring to explain the delegation and checkpoint's no-op guard behavior

2. **Added test to `test/engram/notes/crdt_persistence_test.exs`:**
   - New test: `"unbind materializes trailing edits into notes.content and bumps seq"`
   - Verifies that trailing edits made after the last checkpoint are materialized into `notes.content` and that `seq` is incremented
   - Follows the TDD pattern: bind → edit → unbind → verify content changed + seq bumped

### Why This Works

The previous `unbind/3` implementation only updated the CRDT state snapshot (`crdt_state_ciphertext` / `crdt_state_nonce`), leaving `notes.content`, `content_hash`, and `seq` untouched. This meant trailing edits made in the last settle window before room exit were never visible to REST API calls, search, or legacy bulk pullers.

`CrdtCheckpoint.checkpoint/4` does the full materialization:
- Encodes the full doc state
- Materializes plaintext columns: `content`, `content_hash`, `title`, `tags`
- Bumps `version` and `seq` (when content changed)
- Enqueues a debounced embed job
- Has a **no-op guard**: when the doc's projected content hash equals the row's current hash, it only compacts the snapshot with no version/seq bump, making it safe to call on every room exit

By delegating to checkpoint, unbind now:
- Materializes trailing edits into content/hash/seq for the REST layer
- Triggers embeddings when content changes
- Avoids phantom seq/version bumps when the doc is unchanged (no-op guard)
- Inherits checkpoint's error handling (logs and returns :ok on internal failures)

### Test Expectations

No existing test expectations needed updating. The new test directly validates the bug fix:

```elixir
test "unbind materializes trailing edits into notes.content and bumps seq", ctx do
  # Setup: bind to populate crdt_state from notes.content
  # Edit: diff_into_text with "trailing edit never checkpointed"
  # Action: CrdtPersistence.unbind (now delegates to checkpoint)
  # Verify: updated.content includes the trailing edit AND seq > original_seq
end
```

All 27 tests pass (crdt_persistence_test.exs + crdt_checkpoint_test.exs).

## Verification

```bash
$ cd /home/open-claw/documents/code-projects/engram/.worktrees/fix-crdt-sync-hardening
$ mix test test/engram/notes/crdt_persistence_test.exs test/engram/notes/crdt_checkpoint_test.exs --seed 0
Running ExUnit with seed: 0, max_cases: 20
Excluding tags: [:qdrant_integration, :cluster, :integration]

...........................
Finished in 4.3 seconds (0.00s async, 3.7s sync)
27 tests, 0 failures
```

All tests pass including the new materialize test and all existing unbind/checkpoint tests.

## Notes

- No mix.exs version bump (per spec)
- No push (per spec)
- CrdtCheckpoint.checkpoint/4 never raises on internal failures (logs and returns :ok) — unbind remains safe during room terminate
- The checkpoint's no-op guard (compare content_hash before/after) prevents version/seq churn when unbind is called with an unchanged doc

---

## Review Finding Fixes (post-task-3 review)

**Commit:** `a71fb4b7` (amend of task-3 commit)

### Finding 1 (Important): checkpoint/5 can raise — make it genuinely no-raise

**Root causes identified:**
- `Accounts.get_user!(user_id)` raises `Ecto.NoResultsError` when user deleted while room live
- Bare `{:ok, prev_hash} = Repo.with_tenant(...)` match raises `MatchError` on DB failure
- `Vaults.next_seq!` inside the transaction can raise

**Red evidence (before fix):**
```
1) test checkpoint returns :ok instead of raising when the user row is gone
   ** (Ecto.NoResultsError) expected at least one result but got none in query:
   from u0 in Engram.Accounts.User,
     where: u0.id == ^"baada1f8-7606-4592-9355-1dc7a12b2012"
   code: CrdtCheckpoint.checkpoint(Ecto.UUID.generate(), vault.id, note.id, doc)
   stacktrace:
     lib/engram/notes/crdt_checkpoint.ex:36
11 tests, 1 failure
```

**Fix:** Added implicit `rescue` clause at the end of `checkpoint/5` (after the `else` block, before the closing `end`). Used the implicit form — `rescue` is a peer clause of `do`/`else` in the `def`, not a nested `try`. The rescue logs via the `crdt checkpoint raised` pattern with `Exception.format(:error, err, __STACKTRACE__)` and returns `:ok`. All existing logic inside the function is unchanged.

**Green evidence (after fix):**
```
11 tests, 0 failures   (crdt_checkpoint_test.exs, seed=0)
```

### Finding 2 (Minor): crdt_persistence.ex stale comments

Updated two comment locations to match reality:
1. `@moduledoc` bullet for `unbind/3`: replaced "flush a compacted snapshot / Done asynchronously" with accurate description (full synchronous checkpoint, materializes content/content_hash/seq, enqueues embed, degrades to snapshot-compaction when text unchanged).
2. Inline comment block directly above `unbind/3`: replaced old description with accurate one, also noting that raises inside checkpoint are caught and logged there so unbind always returns `:ok`.

### Full directory test summary

```
mix test test/engram/notes/ --seed 0
Running ExUnit with seed: 0, max_cases: 20
Excluding tags: [:qdrant_integration, :cluster, :integration]

Finished in 9.6 seconds (2.4s async, 7.2s sync)
210 tests, 0 failures
```
