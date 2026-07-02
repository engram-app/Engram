# Task 2: Checkpoint Skips Version/Seq Bump When Content Is Unchanged

## Status: DONE

**Commit SHA:** `1ed46e37fef4364a6ab94440d8240a7168c863bf`

**Test Summary:** 10 tests pass (all existing tests + 1 new test for unchanged-content path)

## Implementation Summary

### Changes Made

1. **Test Added** (`test/engram/notes/crdt_checkpoint_test.exs`)
   - New test: `checkpoint with unchanged content compacts crdt_state without bumping version/seq`
   - Verifies that when content hash is unchanged:
     - `version` stays the same (not bumped)
     - `seq` stays the same (not bumped)
     - No new EmbedNote job is enqueued
   - Follows the same job-counting pattern as the adjacent embed-skip test

2. **Implementation** (`lib/engram/notes/crdt_checkpoint.ex`)
   - Added branching logic after `prev = note.content_hash` inside the `Repo.with_tenant` block
   - **Unchanged-content path** (`if prev == content_hash`):
     - Uses `Repo.update_all` to update ONLY:
       - `crdt_state_ciphertext`
       - `crdt_state_nonce`
       - `dek_version`
     - Prunes the tail (via `prune_tail/2`)
     - Returns `{:ok, prev}` without bumping version or seq
   - **Changed-content path** (else branch):
     - Preserves the original full-materialization logic unchanged
     - Bumps version and seq as before
     - Re-encrypts content/title/tags
     - Calls inject_phase_b_fields_pub
     - Enqueues embed via the existing logic below the branch

### Design Rationale

The unchanged-content optimization prevents unnecessary churn:
- Without this guard, every room exit in Task 3 would call checkpoint
- Checkpoints would unconditionally bump version + seq even without text changes
- Legacy `/changes` pullers would see phantom edits (seq increments) with no actual note modification
- This path compacts the CRDT state snapshot while keeping the row's version/seq/content stable

## Test Results

```
Running ExUnit with seed: 0, max_cases: 20
Excluding tags: [:qdrant_integration, :cluster, :integration]

..........
Finished in 3.7 seconds (0.00s async, 1.9s sync)
10 tests, 0 failures
```

All tests pass:
- `checkpoint persists live doc state + plaintext + bumps seq + prunes tail` ✓
- `checkpoint does not corrupt title or path_hmac on a note with a non-trivial path` ✓
- `checkpoint enqueues a debounced embed when content changes` ✓
- `checkpoint does NOT enqueue an embed when content is unchanged` ✓
- `prune_tail keeps rows inserted AFTER the watermark was captured` ✓
- `a tail row inserted after the watermark survives prune even when checkpoint runs later` ✓
- `checkpoint with a nil watermark prunes nothing` ✓
- `CrdtCheckpointTimer debounces — activity signals reset the settle timer` ✓
- `CrdtCheckpointTimer exits when room exits` ✓
- **`checkpoint with unchanged content compacts crdt_state without bumping version/seq` ✓** (new)

## Verification

1. ✅ Failing test written and confirmed to fail (version was being bumped)
2. ✅ Implementation added per the brief's exact specification
3. ✅ All 10 tests pass with `--seed 0`
4. ✅ Code formatted with `mix format`
5. ✅ Commit created with the brief's exact message
6. ✅ No mix.exs version bump (as instructed)
7. ✅ No push (as instructed)

## No Concerns

The implementation is straightforward and follows the brief exactly. The branching logic is clear, and the unchanged-content path does exactly what's needed: compact the snapshot without touching version/seq/content fields.

---

## Latent Bug Fix (post-review, same commit 5e03c1c4)

**Bug:** `Repo.with_tenant/2` wraps the fun's return in `{:ok, _}` (Ecto transaction semantics). Both branches of the `if prev == content_hash` block returned `{:ok, prev}`, so the outer `{:ok, prev_hash} = Repo.with_tenant(...)` bound `prev_hash = {:ok, prev}` — a tuple, not a binary. The embed gate `if prev_hash != content_hash` was comparing tuple != binary, which is always true, so an embed job was enqueued on EVERY checkpoint. Oban's uniqueness window mostly deduplicated these, masking the bug in tests.

**Fix (`lib/engram/notes/crdt_checkpoint.ex`):**
- Both branches inside the `with_tenant` fun now return bare `prev` (the binary hash), not `{:ok, prev}`.
- Added a one-line comment above the outer match explaining the wrapping semantics.

**Test strengthening (`test/engram/notes/crdt_checkpoint_test.exs`):**
- The "checkpoint with unchanged content compacts crdt_state without bumping version/seq" test now calls `Repo.delete_all(Oban.Job)` before checkpoint to eliminate Oban uniqueness as a masking factor, then uses `refute_enqueued(worker: EmbedNote)` instead of a job-count delta assertion.

**TDD evidence:**
- RED: With the strengthened test in place but `{:ok, prev}` still returned by both branches, `refute_enqueued` failed with "Expected no jobs matching EmbedNote to be enqueued" — 1 failure, 9 passing.
- GREEN: After changing both branches to return bare `prev`, all 10 tests pass (`mix test test/engram/notes/crdt_checkpoint_test.exs --seed 0` — 10 tests, 0 failures).
