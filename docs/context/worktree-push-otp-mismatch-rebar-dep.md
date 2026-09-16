# Context Doc: Wrong-OTP `git push` from a worktree corrupts the `opentelemetry` rebar build

_Last verified: 2026-09-16_

## Status
Working (documented gotcha — recovery is two commands; always push with `mise exec --`)

## What This Is

A bare `git push` from a backend worktree runs the pre-push quality gates under
whatever `mix`/`erl` is on `PATH`. On this machine that is the **system Erlang
(erts-14 / OTP 26)**, not the project's OTP 27. The OTP-26 run writes rebar3
artifacts into `deps/opentelemetry/_build/`; the next correct OTP-27 run cannot
restore that dep's compiler DAG, `:opentelemetry` fails to build, and the push
is rejected.

## Symptom

Any one of these means you are here:

- `git push` from a worktree hangs for minutes, or is rejected, at the pre-push gates.
- `mix` output mentions `erts-14` / OTP 26 while the project expects OTP 27.
- The push fails with:

```
Failed to restore .../deps/opentelemetry/_build/prod/lib/.rebar3/rebar_compiler_erl/source.dag file. Discarding it.
===> {missing_module,opentelemetry_sup}
** (Mix) Could not compile dependency :opentelemetry
```

The credo gate then fails because Stage B needs a compiled app.

## Root Cause

`.githooks/pre-push` (the repo sets `core.hooksPath=.githooks`) runs the quality
gates **before any remote transfer** — Stage A is `mix format` + `mix compile
--warnings-as-errors` in parallel, Stage B is `credo` + `sobelow`. Those gates
invoke `mix` from `PATH`. The project pins `erlang 27.3.4.14` /
`elixir 1.17.3-otp-27` in `.tool-versions` via mise, so only a `mise exec --`
invocation gets the right toolchain; a bare shell gets the system OTP 26.

`:opentelemetry` is a rebar3 dep. Compiling it under OTP 26 leaves a
`source.dag` the OTP-27 rebar cannot read, so rebar discards it and then reports
`missing_module,opentelemetry_sup`.

The push exits 1 before contacting the remote, so nothing lands half-pushed.

## Fix

```bash
mise exec -- mix deps.compile opentelemetry --force
mise exec -- git push
```

Prefix **both** `mix` and `git push` with `mise exec --` from a worktree. See
also `feedback_backend_mise_exec_otp27` — this is the same PATH trap, reached
through the push hook instead of a direct `mix` call.

## Blast radius — it is not worktree-local

`.githooks/post-checkout` **hardlinks** `deps/` and `frontend/node_modules` from
the canonical checkout into every new worktree (it prints
`post-checkout: hardlinked deps from ...`). Verified in the incident:
`deps/opentelemetry/src/opentelemetry_sup.erl` had an **identical inode** in the
worktree and in the main checkout. A wrong-toolchain compile inside a worktree
can therefore reach the main checkout's dependency tree.

In the observed case the damage was contained — the mix-level
`_build/dev/lib/opentelemetry/ebin` still held all 33 beams in **both**
locations and the main checkout's own `_build` was intact; only the dep's nested
rebar3 build was discarded. **Do not assume that bound always holds.** Check both
trees before concluding the blast radius was worktree-only.

## Gotchas

- **`pkill -f` on a stuck push kills the replacement too.**
  `pkill -f "git push -u origin <branch>"` also matches the shell wrapper of the
  *next* command containing that same string, so the retry dies immediately with
  exit 144. Kill by PID, or use a pattern that cannot match the new command.
  Same self-match failure already documented for `pkill -f session-manager-plugin`.

- **`cmd | tail` returns tail's exit code.** `mix test | tail -8` reported
  success while the suite actually had a failure. Redirect to a file and echo
  `$?`. Already recorded in `AGENTS.md` → Testing → "Never pipe a gate command
  through `tail`"; it recurred here.

- **Related toolchain drift: biome.** `frontend/package.json` pins
  `@biomejs/biome` 2.5.12, but a worktree's hardlinked `node_modules` can carry
  2.5.11, which aborts with a CONFIG error (unknown rule names) on **every** file
  including untouched ones — frontend lint is unverifiable locally in that state.
  Reproduce CI's version without mutating the shared `node_modules`:

  ```bash
  bunx @biomejs/biome@2.5.12 check --error-on-warnings <paths>
  ```

  CI's `frontend-lint` job installs its own deps and is authoritative.

## References

- `.githooks/pre-push`, `.githooks/post-checkout`
- `.tool-versions` (erlang 27.3.4.14 / elixir 1.17.3-otp-27)
- Sibling worktree/hardlink failure with a different root cause (missing
  yecc/leex-generated beams) → `docs/context/worktree-deps-artifact-staleness.md`
- `AGENTS.md` → "Quality Tooling" (pre-push hook stages), "Testing" (pipe-to-tail rule)
