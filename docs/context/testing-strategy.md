# Context Doc: Testing Strategy

_Last verified: 2026-10-03_

## Status
Working — ExUnit tests cover business logic and HTTP contract via ConnCase. E2E tests verify real Obsidian sync workflows against Docker stack.

## What This Is
Testing philosophy, test layers, tooling, and CI pipeline for the Engram Elixir/Phoenix backend.

## Philosophy

**Tests are the spec. If a test fails, fix the app — not the test.**

## Test Layers

| Layer | Location | Command | What it tests | Infra needed |
|-------|----------|---------|---------------|--------------|
| **Unit/ConnCase tests** | `test/` | `mix test` | Business logic, HTTP contract, auth, RLS, plugs | Postgres (Ecto.Sandbox) |
| **E2E tests** | `e2e/tests/` | `python3 -m pytest e2e/tests/ -v` | Real Obsidian sync: push/pull, Channels, conflicts, multi-user | CI stack + Obsidian |
| **E2E harness unit tests** | `e2e/unit/` | `cd e2e/unit && python3 -m pytest -v` | Harness helpers (cleanup SQL safety, timeout budgets, probes) | None |
| **Headless protocol** | `e2e/headless/` | `headless-protocol` CI job | Real plugin SyncEngine vs real backend over WS, no Obsidian | Backend stack |
| **Plugin sim tier** | plugin repo `tests/sim/` | `bun test tests/sim/` (plugin) | Seeded deterministic CRDT convergence | None |

## Elixir Testing Stack

| Tool | Purpose |
|------|---------|
| **ExUnit** | Test framework |
| **Ecto.Adapters.SQL.Sandbox** | Per-test DB transactions (auto-rollback) |
| **ExMachina** | Test data factories |
| **Mox** | Behaviour-based mocks (embedder, Qdrant client) |
| **Bypass** | HTTP mock server (for Voyage AI, Qdrant API) |

Key advantage: `async: true` runs tests in parallel with per-test DB transactions. No cleanup needed.

## Running locally

See `docs/context/local-backend-testing.md` (`scripts/test-local.sh`). A fresh
DB needs Postgres 18+ (`uuidv7()`); plain `mix test` runs
`engram.prepare_database` via the `test` alias. Hand-rolling
`mix do ecto.create, ecto.migrate, test` skips it and dies on the baseline's
`GRANT ... TO engram_app`.

## RLS Testing

Naive isolation tests prove nothing: the suite connects as a superuser, which
bypasses RLS. See `docs/context/rls-enforcement-testing-traps.md` before
writing a tenant-scoping test.

## CI Pipeline

All tests run in GitHub Actions (`.github/workflows/verify.yml`):

1. **Unit tests**, `mix test`. The stack-free `e2e/unit` harness tests run as a step of the `e2e-clerk` job
2. **E2E tests**, CI stack + headless Obsidian, full sync scenarios. Report-only on PRs; see `docs/context/testing-architecture-migration.md` and `docs/context/ci-pipeline-gating.md`

**Code quality checks:** `mix format --check-formatted` and `mix credo --strict` (both fatal in the `lint` job). Dialyzer, sobelow and compile-with-warnings are also fatal; see "Quality tooling" below.

## References
- ExUnit tests: `test/`
- E2E tests: `e2e/tests/`
- CI config: `.github/workflows/verify.yml`

## Local gate loop before pushing

_Moved from AGENTS.md on 2026-10-28._


The full `mix test` is **~9 min** and cannot be sped up by your machine: **217 of
441 test files are `async: false`**, so a measured run is
`Finished in 526.0s (57.4s async, 468.6s sync)` — ~89% strictly sequential on one
core. Running it blocks the edit loop while CI would run it in parallel, on the
faster runner, for free. Four full local runs in one session (2026-08-18) cost
~36 min and caught nothing CI would not have.

**Run locally before committing/pushing:**

```bash
mix format && mix credo --strict          # ~25s
mix dialyzer                              # ~30-35s with a warm PLT — do NOT skip
mix test <files-you-changed> test/lint/ --warnings-as-errors
```

- `test/lint/` is mandatory even on a targeted run — those are full-suite-only
  meta-tests (e.g. `notes_scope_lint_test.exs`) a targeted run otherwise skips.
- `--warnings-as-errors` because CI applies it to *test* code and the pre-push
  hook does not. Without it CI aborts **after a fully green run** with
  `Test suite aborted after successful execution due to warnings`, which reads
  like an infra failure rather than a code problem. Caveat: the flag only fails
  on warnings emitted while *compiling the files that run recompiled*, so with a
  warm `_build` an unchanged file emits nothing and the gate silently passes —
  introduce a warning, run once (red), re-run without editing, green. CI builds
  cold and catches it anyway. To actually reproduce CI, force the compile:
  `mix compile --force --warnings-as-errors`.
- Never run `mix dialyzer` and `mix test` concurrently — parallel dialyzer
  saturates the box, drops postgres connections, and fabricates failures
  scattered across unrelated modules. The tell is scatter; re-run alone.
- Never pipe a gate command through `tail` — `mix test | tail -25` returns
  *tail's* exit code (a fake 0) and truncates the failure block. Redirect to a
  file instead.

CI is the gate for the full suite and e2e. **Never merge on red** is unchanged.

See `docs/context/testing-strategy.md` for full strategy, tooling, and CI pipeline.

## A test must be able to fail

A green test is worth nothing until you know what makes it red. Three rules,
each written after a test in this repo proved nothing for an unknown number of
runs.

**1. A negative test's name must describe the exact thing being denied, and its
body must construct that exact case.**

`folders_controller_test.exs` had a case named *"404 when marker doesn't belong
to caller's vault"* whose body passed `Ecto.UUID.generate()` — an id belonging
to no vault at all. It proved the not-found path. A controller that looked
markers up globally and ignored the caller's vault entirely would have passed
it unchanged (#1562).

If the name says *another vault*, build a marker in another vault. If it says
*another user*, build another user. "Nonexistent" is a third, separate case.

**2. A test that reaches into another layer's internals must fail loudly when
the symbol it reaches for is gone.**

The e2e fan-out tests proved delivery by stubbing every alternate path to a
no-op. Every method name they stubbed had been retired from the plugin, and the
`typeof` guard skipped what was missing — so they stubbed **nothing**, and four
"TRUE fan-out proof" tests ran green with the feature dead (#1503, fixed in
#1559).

Prefer counting a call over disabling its alternatives: a pass-through wrapper
cannot break the code under test, and a rename leaves the counter at zero
instead of silently widening what satisfies the assert. Where a test must name
a foreign symbol, assert the symbol exists — `e2e/conftest.py`'s session-start
surface check is the pattern.

**3. For a scoping, auth, or boundary test, mutate the guard and watch it go
red before you trust it.**

Not tooling — by hand, once, at write time. Drop the predicate, run the one
file, confirm the failure, revert. #1562's vault-scoping case was verified this
way, and the mutation also revealed that the sibling cross-user case is
defended by RLS rather than by the query, so it stays green under the same
mutation. That distinction is invisible without mutating, and it is the
difference between two tests and one test plus decoration.

## Claims about the system carry their evidence

In PR bodies, issue comments and commit messages, label a claim by how you know
it: **measured** (with the number and where it came from), **deduced** (from
code you read — say so), or **assumed**. Do not promote a deduction to a fact
because it is probably right.

Worked example, both from one afternoon: *"api_only costs ~0 wall clock"* was
repeated from a comment in `verify.yml` and used to justify a decision; the
measured step times are 120s (e2e-crdt) and 86s (e2e-clerk) with a 0s follow-on
wait, so it was on the critical path the whole time. In the same window, *"a
failed fingerprint yields a green ci"* was stated as fact, and it is a sound
deduction from the workflow structure that has happened **0 times in 998 runs**.
Both were wrong to assert flatly; only one was wrong.

A comment in this repo is an assertion, not a measurement. Cite the run id.

## Quality tooling

All quality lints are fatal in CI (`lint` job in `.github/workflows/verify.yml`): `mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix credo --strict`, `mix sobelow --exit low --skip`, `mix dialyzer`. Configs: `.credo.exs`, `.sobelow-conf`, `.sobelow-skips`, `.dialyzer_ignore.exs`. The PLT is cached on the `mix.lock` hash.

```bash
mix format --check-formatted              # fast
mix compile --warnings-as-errors --force  # fast
mix credo --strict --mute-exit-status     # ~3s
mix sobelow --exit low --skip             # ~5s (--skip honours .sobelow-skips; MUST match CI)
mix dialyzer                              # ~32s warm; ~8 min the FIRST time in a new worktree (PLT re-key)
```

Pre-push hook (`.githooks/pre-push`, activate with `git config core.hooksPath .githooks`) runs format, compile, credo and sobelow; dialyzer is skipped there (too slow), so run it yourself. Ratchet rule: a lint is fixed to zero findings, then made fatal, and new findings fail CI. Deferred ratchets: `Readability.Specs` (`@spec` on every public function, ~225 outstanding) and `Design.DuplicatedCode` (13 outstanding).
