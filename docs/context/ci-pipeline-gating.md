# CI pipeline & gating (post testing-architecture migration)

Canonical reference for what runs in `verify.yml` / `deploy-prod.yml`, on which
trigger, and — crucially — what **gates** (blocks a merge/deploy) versus what
merely **runs and reports**. Written after the 2026-07 testing-architecture
migration that moved the merge gate off the flaky real-Obsidian e2e suite and
onto deterministic proofs.

## The one idea

The migration did **not** stop e2e from running on PRs. It stopped e2e from
**gating** PRs. The real-Obsidian suites still execute on a PR and post their
own red/green check — they just no longer count toward "can this merge." The
merge gate is now the **deterministic** layer:

- backend `unit-tests` (includes the CRDT head-consistency **property test**),
- the plugin **sim tier** (seeded convergence sim, differential gate for #282),
- and the new **headless-protocol** tier (real engine vs real backend, event
  barriers, no Obsidian) — currently report-only, baking toward required.

Flaky is no longer blocking, but flaky is still **visible** and still hard-gates
`main`, the nightly run, and every release.

## Triggers

| Trigger | Meaning | `is-full`? |
|---|---|---|
| push to a branch (PR) | Normal PR validation | ❌ fingerprint decides what to skip |
| push to `main` (post-merge) | Full safety-net run | ✅ forced |
| `schedule` (06:00 UTC) | Nightly full run + flake measurement | ✅ forced |
| `workflow_dispatch` `force_full=true` | Manual "run everything" | ✅ forced |
| `repository_dispatch` | Backend runs e2e for a **plugin** PR, posts a `backend/e2e` status back | — |
| `release-v*` tag | `deploy-prod.yml` → release e2e gate → deploy | ✅ (force_full) |

`is-full` (computed by the `fingerprint` job) forces the full suite to actually
execute instead of cache-skipping. It is true on `main` pushes, `schedule`,
`[ci-full]` in the commit message, and `force_full` dispatch.

## Jobs (verify.yml) — what each does and whether it gates

### Deterministic gate — these BLOCK a PR merge (aggregated by `ci`)

| Job | What it does |
|---|---|
| `version-check` | mix.exs is valid semver (branches only; skipped on main / dependabot) |
| `unit-tests` | `mix test` — includes the CRDT head-consistency property test (deterministic convergence proof) |
| `lint` | format + credo + compile-warnings-as-errors |
| `frontend-lint` | SPA build/lint + legal-manifest hash (skipped on cross-repo dispatch) |
| `storage-database` | storage + DB-layer tests |
| `static-checks` | dialyzer / static analysis |
| `migration-gates` | migration immutability + `phase/*` gates (deploy guardrail) |

### Report-only — RUN on PRs but do NOT block merge

| Job | What it does | Where it DOES gate |
|---|---|---|
| `e2e-clerk` | Real Obsidian + Clerk auth E2E | main / nightly / release |
| `e2e-crdt` | Real Obsidian CRDT sync E2E | main / nightly / release |
| `e2e-browser` | Real browser / SPA E2E | main / nightly / release |
| `headless-protocol` | Real SyncEngine vs real backend over WS, event barriers, no Obsidian/Xvfb | (baking — report-only everywhere until it graduates) |

### Infra / orchestration — not gates, they make the above work

| Job | What it does |
|---|---|
| `fingerprint` | Hashes inputs → emits cache-hit signals + `is-full`; decides which jobs skip |
| `prebuild-ci-image` | Builds/loads the shared engram CI docker image |
| `prebuild-mix` | Builds/caches mix deps + `_build` |
| `ci` | **The single required aggregate** — normalizes skipped jobs, fails on any deterministic red, downgrades e2e to `::warning::` |
| `record-pass` / `record-job-markers` | Persist green fingerprints so an identical/no-op push short-circuits next time |
| `report-e2e-to-plugin` | Posts the `backend/e2e` cross-repo status to a plugin PR (see "two-repo entanglement") |
| `build-and-publish-image` / `deploy-frontend` / `submit-dep-graph` | Post-merge / main artifact + dep-graph work |

### Measurement only — nightly

| Job | What it does |
|---|---|
| `ledger-append` | On the nightly `schedule`, appends one JSONL line per suite (`e2e-clerk/crdt/browser` **+ `headless-protocol`**) to the `ci-ledger` orphan branch and prints a trailing-14-night flake rate. Never gates. This is the evidence that decides when `headless-protocol` graduates to required. |

## Why `ci` is the only required check

Branch protection requires just `ci` (plus `unit-tests`, `lint`) — not the
individual e2e jobs. That is deliberate: `ci` encodes the policy in **logic**,
not in branch protection. The ruleset says "`ci` must pass"; the `ci` job
internally decides a flaky e2e is a `::warning::` while a red unit-test is
`::error::`. So the de-gate was a workflow edit, never a ruleset edit.

`ci`'s `needs`: `[fingerprint, version-check, unit-tests, lint, frontend-lint,
storage-database, e2e-clerk, e2e-crdt, e2e-browser, migration-gates,
static-checks]`. It exits non-zero only if a **deterministic** need failed;
`e2e-*` failures become warnings.

A **skipped** required check counts as passing to GitHub rulesets, which is why
a workflow-only or cache-skipped PR shows `ci: skipped` yet is mergeable.

## Gate summary by context

| Check | PR | main (post-merge) | nightly | release (`release-v*`) |
|---|---|---|---|---|
| Deterministic (unit/lint/migration/…) | 🔒 gate | 🔒 gate | runs | 🔒 gate |
| Real-Obsidian e2e | 👁 report | 🔒 gate | 🔒 gate + logged | 🔒 **blocks deploy** |
| `headless-protocol` | 👁 report | 👁 report | 👁 logged | — |
| Flake ledger | — | — | ✍️ writes | — |

🔒 blocks · 👁 runs but informational · ✍️ measures

## The release gate (deploy-prod.yml)

Pushing a `release-v*` tag triggers `deploy-prod.yml`. Its `release-e2e-gate`
job dispatches `verify.yml` with `force_full=true` against the **exact tagged
commit** and **blocks the deploy if any real e2e suite fails** — the "real-app
proof before ship" that replaces PR-time e2e gating.

- Override (emergency ship): put `[skip-release-e2e]` in the **annotated** tag
  message.
- Note: `verify.yml` ignores `release-v*` tags itself; the gate dispatches it
  explicitly with `force_full` so the fingerprint is bypassed.

## Two-repo entanglement (plugin PRs)

A **plugin** PR dispatches the backend e2e suite cross-repo; the backend's
`report-e2e-to-plugin` job posts a `backend/e2e` commit status onto the plugin
commit. As of **#1081** that status is **no longer required** on plugin PRs — it
still runs and posts (visible), but the plugin merge gate is `build-and-test`,
which runs the unit suite **and** the sim differential gate (deterministic
convergence proof). This mirrors the backend policy (e2e report-only-but-visible).

Plugin required checks live in `engram-infra/main/github/repos.tf`
(`Engram-obsidian.required_checks`), rendered into the ruleset by `rulesets.tf`
and applied by engram-infra `ci.yml` on merge to main. To re-impose a
cross-repo e2e gate later, point it at the deterministic **headless tier** once
that graduates, not at the flaky Obsidian suites.

## Related

- Backend de-gate + sim tier + fence fix: see the testing-migration memory and
  `docs/context/testing-architecture-migration.md`.
- Sim fidelity gaps: `docs/context/crdt-convergence-sim-fidelity-gaps.md`.
- Runner infrastructure: `docs/context/runner-vm-setup.md`.
