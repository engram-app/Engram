# CRDT id-keyed rename — old-path resurrection on the receiver

_Last verified: 2026-07-06_

**Status:** root-caused + fixed 2026-07-06 (plugin PR engram-app/Engram-obsidian#183,
branch `fix/crdt-rename-old-path-resurrection`).
**Symptom:** e2e `test_10_rename_propagation` flaked ~50% in e2e-clerk — after an
id-keyed rename the receiver kept the OLD path (both old and new files present, or
old never trashed). Intermittent because it's a same-seq ordering race.

## What this is

Two interacting defects in the Obsidian plugin `src/sync.ts` `handleStreamEvent`.
Both are receiver-side; the backend is behaving as designed.

## Root cause

1. **Backend emits a delete + an upsert for one rename.** `Notes.rename_note`
   UPDATEs the live row in place (note_id/PK preserved) AND inserts a soft-deleted
   tombstone at the OLD path (fresh id, same seq) — deliberate, for the #614
   offline-resurrection fix. So both the `/sync/changes` cursor feed and the realtime
   broadcast carry an **old-path delete + a new-path upsert (same note_id)**.
   `moveIfIdRelocated`'s comment wrongly assumed "no separate delete for the old path."
2. **The CRDT room is keyed by note_id and stays bound to the OLD path** across the
   rename. Shared-room CRDT channel traffic re-materializes + re-pushes the old path,
   landing it in the echo-suppression set (`pushing` / `recentlyPushed`).
3. **Echo-suppression ran too early and too broadly.** `handleStreamEvent`'s
   echo-suppression early-return fired for ALL event types and ran BEFORE both the
   delete branch and `moveIfIdRelocated`. Result: (a) the server's authoritative
   old-path DELETE was swallowed as an "echo" (`Echo skip (recently pushed): delete …`),
   and (b) the new-path UPSERT was echo-skipped before reaching `moveIfIdRelocated`,
   so the room was never relocated → perpetual resurrection of the old path.

## The fix (plugin #183, two commits)

- **Exempt `delete` events from echo-suppression.** A delete is never an echo of a
  content push; a redundant delete no-ops.
- **Hoist `moveIfIdRelocated` to run BEFORE the echo-suppression early-return.** It's
  idempotent (no-ops unless the id maps to a different local path), so it relocates
  the room + trashes the old file even when the upsert body-apply is echo-skipped.
- Failing-first unit tests: "delete event is honored even when the path was recently
  pushed" (`tests/sync.test.ts`) and "relocation runs even when the new path was
  echo-suppressed" (`tests/sync-note-id.test.ts`).

**Verified:** test_10 passed 6/6 e2e-clerk runs with both fixes (was ~50% flaky).
Baseline with ONLY the delete-exemption still flaked — the relocation bypass remained.

## Diagnostic method (the reusable part)

- The e2e failure artifact `ci-debug-<sha>` contains `docker-compose.log`, which
  carries **suite-wide client logs** (remote logging, #909). Client lines carry
  `metadata.device_id` (per-device attribution) and category tags: `[client:ws]`,
  `[client:pull]`, `[client:channel]`, `[client:push]`.
- Extract per-note, device-attributed, time-ordered client logs with a small python
  json filter on the rename path suffix. Each test run uses unique
  `RenameOld-<suffix>.md` / `RenameNew-<suffix>.md` paths (PR #927), so this cleanly
  isolates which device keeps the old path and which branch fired.
- Temporary instrumentation that cracked it: log every `moveIfIdRelocated` call with
  `id` / `newPath` / `priorPath` (not just when it trashes), and include `event_type`
  in the echo-skip log line (a swallowed DELETE reads very differently from a swallowed
  upsert).
- The bug is a same-seq ordering race (upsert vs delete of the same note), hence
  intermittent. Snapshot asserts flaked; engram#928 converted them to polls, but the
  product bug was the real cause.

## Dead ends

- **Local CRDT e2e repro could NOT reproduce this** (`docs/context/local-crdt-e2e-repro.md`).
  The local stack image (0.5.558) predates the #925 rename-tombstone backend change
  and fails differently (rename never reaches the server). Use CI e2e-clerk:
  `gh workflow run CI --ref main -f plugin_branch=<branch> -f force_full=true`
  (auto-pairs the plugin branch). Failure artifacts upload only on failure, so
  re-roll to catch the ~50% flake.

## Related

- engram#928 — test poll asserts (now redundant for correctness, reasonable hardening).
- plugin #180 / #181 / #182 — CRDT id-keying + earlier receiver-move attempts.
- engram#925 — backend id-keying.
