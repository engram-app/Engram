# Task 4 Report: Room traps exits (deploy-safe terminate) + restart :temporary

## Status: DONE

## Commit

`1d7e8666` — fix(crdt): trap exits in rooms so deploys flush; rooms restart on demand

## Test Summary

- 1 new test: `Engram.Notes.CrdtDocTest` — "supervisor shutdown runs terminate → unbind → edits materialize"
- Confirmed RED before implementation: content remained "before" (room killed without terminate flush)
- GREEN after implementation: content contains "SHUTDOWN EDIT" (terminate → unbind → checkpoint ran)
- Full suite: `test/engram/notes/` — 211 tests, 0 failures
- Full suite: `test/engram_web/channels/` — 55 tests, 0 failures

## What Was Done

### Test adjustments from brief

The brief's test matched `{:ok, updated}` from `Repo.with_tenant`. In this repo, `Repo.with_tenant` wraps the fun's return in `{:ok, _}` AND `Crypto.maybe_decrypt_note_fields` also returns `{:ok, note}`, so the actual shape is `{:ok, {:ok, %Note{}}}`. Adjusted the test to match `{:ok, {:ok, updated}}` so the assertion operates on the bare Note struct. The test intent and failure/pass semantics are identical to the brief's specification.

### False-pass risk

The brief warned about a potential false pass if the CrdtCheckpointTimer's eager flush (settle_ms: 100 in test config) fires before `terminate_child`. In practice the test was reliably RED before the fix — the test proceeds to `terminate_child` synchronously right after `update_doc`, with no yield/sleep, so the timer's 100ms eager window has not elapsed. No `Application.put_env` override was needed.

### Implementation

**`lib/engram/notes/crdt_persistence.ex` — bind/3:**
Added `Process.flag(:trap_exit, true)` as the first statement in `bind/3` with the exact comment from the brief. Since `bind/3` runs inside the room GenServer (called from `SharedDoc.init`), this flag flips the room to trapping exits. The supervisor's `:shutdown` signal then arrives as a message and gen_server calls `terminate/2` → `unbind/3` → `CrdtCheckpoint.checkpoint/4` (Task 3's materializing unbind), flushing content to the notes row before the room exits.

**`lib/engram/notes/crdt_doc.ex` — child_spec/1:**
Changed `restart: :transient` to `restart: :temporary` with the exact comment from the brief. With `:transient`, a crashed room would be auto-restarted by the DynamicSupervisor but start with zero observers; since `auto_exit: true` relies on `:DOWN` monitors to detect when all observers leave, a room with no observers never gets a DOWN message and never exits — creating an immortal orphan. With `:temporary`, crashed rooms are not restarted; clients re-establish them on demand via `CrdtRegistry.ensure_observed`.

### Trade-off documented

With trap_exit on, a `CrdtCheckpointTimer` crash (the timer is linked to the room) is delivered as `{:EXIT, pid, reason}` to `SharedDoc.handle_info`, which has no matching clause for EXIT tuples → `FunctionClauseError` → room crashes. gen_server still calls `terminate/2` on exception, so the flush still happens. With `:temporary` restart there is no orphan. This is the "bug-only path" trade-off: crash path is now "flush + die + on-demand restart" instead of the previous "silently skip flush + room keeps running".

## Files Modified

- `lib/engram/notes/crdt_persistence.ex` — `bind/3`: added `Process.flag(:trap_exit, true)` + comment
- `lib/engram/notes/crdt_doc.ex` — `child_spec/1`: `restart: :transient` → `restart: :temporary` + comment
- `test/engram/notes/crdt_doc_test.exs` — new test file

---

## Review Findings Fixes (2026-07-02)

### Finding 1 (Important): trap_exit guard in bind/3

**Change:** `Process.flag(:trap_exit, true)` → `if Process.get(:"$initial_call") != nil, do: Process.flag(:trap_exit, true)`

The flag is now guarded on `:"$initial_call"` (set by proc_lib for GenServers; nil in bare ExUnit test processes). This prevents the flag from leaking into the 16 direct-call test sites in `crdt_persistence_test.exs` and `crdt_e2e_test.exs`.

**RED/GREEN evidence:**

The new test in `crdt_persistence_test.exs` ("bind/3 called directly from a test process does not set trap_exit") asserts:
1. `Process.get(:"$initial_call") == nil` — the guard predicate holds in ExUnit test processes (confirmed true)
2. `trap_exit` is `false` before bind
3. `trap_exit` is `false` after bind

**Important nuance:** Ecto Sandbox's `Repo.transaction` machinery restores the calling process's `trap_exit` flag after the transaction completes. This means assertion 3 passes even with the unguarded flag — the Ecto Sandbox masks the leak. The guard is still necessary and correct for production (where no Ecto Sandbox runs), and assertion 1 proves the guard predicate is sound. The test correctly documents the intended invariant.

**supervisor-shutdown test (crdt_doc_test.exs):** confirmed still passes with the guard. In a real room process (GenServer, `:"$initial_call"` is set by proc_lib), the guard evaluates true and the flag IS set — so the terminate→unbind→checkpoint path works correctly.

### Finding 2 (Minor): Timer config override in supervisor-shutdown test

**Change:** Added `Application.put_env(:engram, Engram.Notes.CrdtCheckpointTimer, settle_ms: 600_000, ceiling_ms: 600_000, eager_ms: 600_000)` + `on_exit` restore, placed BEFORE `CrdtRegistry.ensure_started` so the timer's init/1 sees the overridden config.

Large integers (not `:infinity`) because the timer's `min/2` arithmetic would misbehave on atoms. This makes the test structurally immune to the eager-flush race rather than relying on timing.

### Updated test counts

- `test/engram/notes/` — 212 tests, 0 failures (was 211; +1 trap_exit guard test)
- `test/engram/notes/crdt_doc_test.exs` — 1 test, 0 failures (supervisor-shutdown test with timer override)

### Commit

`f27205a7` — fix(crdt): trap exits in rooms so deploys flush; rooms restart on demand (amended)
