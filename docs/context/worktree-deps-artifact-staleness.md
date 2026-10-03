# Context Doc: Worktree Deps Artifact Staleness (pre-push hook failures)

_Last verified: 2026-10-03_

## What This Is
A worktree's `_build/` can hold an incomplete dep: a missing yecc/leex-generated
`.beam` (`expo`, `jose`) or a dep ebin missing its main module. Compile then
fails in the pre-push hook with a "module not available" error that reads like a
code defect.

## Where the bad `_build` comes from
`.githooks/post-checkout` hardlinks `deps/` and `frontend/node_modules` from the
canonical checkout into each new worktree. Since #1487 (2026-08-27) it
deliberately does **not** seed `_build/`: a hardlinked `_build` let one
worktree's rebuild poison every other's, and a half-built canonical propagated
missing generated beams.

You can still hit this when:
- the worktree was created before #1487, or by a canonical checkout whose
  `.githooks/` predates it (the hook that runs is the canonical's working copy),
  so its `_build` is still hardlinked;
- a dep compile was interrupted and left a partial ebin.

## Symptoms

```
** (UndefinedFunctionError) function :expo_po_parser.parse/1 is undefined
    (module :expo_po_parser is not available)
```

Traced through `Gettext.Compiler.compile_po_file` → `Expo.PO.parse_file!`.
`:expo_po_parser` is generated from `.yrl` sources inside the `expo` dep.

Or, naming **your** file instead of the dep:

```
error: module Hammer is not loaded and could not be found.
 7 │   use Hammer, backend: :ets
    └─ lib/engram_web/rate_limiter/ets.ex:7
```

Here `_build/dev/lib/hammer/ebin/` held only the `Mix.Tasks.Hammer.Install`
beams; `Elixir.Hammer.beam` was absent.

## Fix

Check the ebin directly before theorising:

```bash
ls _build/dev/lib/<dep>/ebin/ | head
```

Then rebuild that dep with `--force`:

```bash
mix deps.compile <dep> --force    # e.g. expo, hammer
mix compile --warnings-as-errors
```

If the worktree's `_build` is still hardlinked (old worktree), break the link:
`rm -rf _build && mix compile`.

## Gotchas

- **`mix deps.compile <dep>` without `--force` silently no-ops.** It prints
  `Generated <dep> app` and exits 0 while the ebin stays incomplete.
- **The canonical checkout compiling clean proves nothing**, and neither does
  `git stash` + recompile in the same worktree. The bad `_build` is the
  worktree's, so both invite the wrong conclusion that `main` is broken.
- Only affects worktrees, not the canonical checkout or a clean `git clone`.

## References

- `.githooks/post-checkout`: what is and is not seeded, and why
- Worktree env files (`.env.local` is gitignored and not carried):
  `../engram-workspace/docs/context/engram-dev-modes.md`
- Same hardlink surface, different root cause (pushing on the system OTP 26
  corrupts the `opentelemetry` rebar build):
  [worktree-push-otp-mismatch-rebar-dep.md](worktree-push-otp-mismatch-rebar-dep.md)
