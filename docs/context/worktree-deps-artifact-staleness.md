# Context Doc: Worktree Deps Artifact Staleness (pre-push hook failures)

_Last verified: 2026-09-18_

## Status
Working (documented gotcha — not a bug, requires manual fix per worktree)

## What This Is
Git worktrees in the engram backend hardlink `deps/` and `_build/` from the parent checkout via the post-checkout hook. Some Erlang deps contain **generated** `.beam` files (from `.yrl`/`.xrl` parser sources) that can be missing or inconsistent in the worktree. This causes `mix compile --warnings-as-errors` failures in the pre-push hook even when `mix test` passes.

## Symptom

Pre-push hook fails with:

```
** (UndefinedFunctionError) function :expo_po_parser.parse/1 is undefined
    (module :expo_po_parser is not available)
```

Traced through `Gettext.Compiler.compile_po_file` → `Expo.PO.parse_file!`. Plain `mix test` may pass; the strict `--force` recompile in the hook is what surfaces the missing generated beam.

A related earlier symptom in the same family: a stale `y_ex` (CRDT lib) artifact causing compile errors, fixed by `mix clean && mix compile`.

## Root Cause

`:expo_po_parser` is a **yecc/leex-generated Erlang module** compiled from `.yrl`/`.xrl` sources inside the `expo` dep (gettext's PO parser). The hardlinked `_build/` artifact can leave this generated `.beam` missing or inconsistent in the worktree because:
- The hardlink is a snapshot; if the parent checkout never fully compiled `expo` (or compiled it under different conditions), the generated beam may not exist in the hardlinked tree.
- The worktree gets a hardlinked reference, not a fresh build.

## Fix

```bash
# In the worktree root:
mix deps.compile expo --force
# Then re-run the hook target:
mix compile --warnings-as-errors
```

This rebuilds the two generated parser files (`.erl` + `.beam`) inside the worktree's `_build/`. For the broader `y_ex`/CRDT class of stale artifacts:

```bash
mix clean && mix compile
```

## Second instance: `hammer` (2026-09-18)

Same class, but the error names **your** file, not the dep:

```
error: module Hammer is not loaded and could not be found.
 7 │   use Hammer, backend: :ets
    └─ lib/engram_web/rate_limiter/ets.ex:7
== Compilation error in file lib/engram_web/rate_limiter/ets.ex ==
```

Nothing points at `deps/hammer`, so this reads like a code defect in the rate
limiter. It is not — `_build/dev/lib/hammer/ebin/` held only the three
`Mix.Tasks.Hammer.Install` artifacts; `Elixir.Hammer.beam` was absent.

Two traps on the way to the fix:

- **`mix deps.compile hammer` (no `--force`) silently no-ops.** It prints
  `==> hammer` / `Generated hammer app` and exits 0 while the ebin stays
  incomplete. Only `rm -rf _build/dev/lib/hammer` first (or `--force`) makes it
  compile the 14 files.
- **The parent checkout compiling clean proves nothing**, and neither does
  checking out an unmodified tree in the *same* worktree — the bad `_build` is
  the worktree's, so `git stash` + recompile still fails and invites the wrong
  conclusion that the breakage is on `main`.

Check the ebin directly before theorising:

```bash
ls _build/dev/lib/<dep>/ebin/ | head
```

## Gotchas

- `mix test` passing is NOT proof that `mix compile --warnings-as-errors` will pass in the hook. The hook uses `--force` which triggers a full recompile and surfaces missing generated beams that the incremental compiler skips.
- Only affects **worktrees** (hardlinked deps), not the parent checkout or a clean `git clone`.
- `mix deps.compile expo --force` is surgical — prefer it over `mix clean && mix compile` (which recompiles everything and takes much longer).

## References

- Related worktree env-file gap (`.env.local` not carried): `docs/context/local-dev-preview-stack.md`
- Broader worktree deps staleness note (lockfile drift, not parser beams): `docs/context/read-path-decrypt-perf.md` line 48
- Worktree usage pattern: `docs/workspace-pattern.md` (workspace root)
- Same hardlink surface, different root cause (pushing on the system OTP 26 corrupts the `opentelemetry` rebar build): `docs/context/worktree-push-otp-mismatch-rebar-dep.md`
