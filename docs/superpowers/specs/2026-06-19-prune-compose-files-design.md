# Prune Compose Clutter: Remove Parity Cluster + Relocate CI Composes — Design

**Date:** 2026-06-19
**Status:** Approved (brainstorming complete; ready for plan)
**Owner:** todd

## Problem

The engram repo root carries **7 `docker-compose.*.yml` files** flat alongside
each other. The root should read as a self-hosting guide — one obvious
`docker compose up -d` path — but a first-time reader sees seven near-identical
filenames and can't tell which one is the product.

A prior pass (`2026-06-05-readme-self-host-simplification`) collapsed the
*self-host* presets (deleted `lite`/`voyage`, single `.env.example`, ~70-line
README) but **deliberately scoped out** the six non-self-host composes. That
deferral is the remaining clutter.

Investigation (2026-06-19) found two distinct problems inside those six:

1. **A dead "parity cluster."** `docker-compose.elixir.yml` +
   `docker-compose.parity.yml` + `lib/mix/tasks/parity.validate.ex` +
   `validate_parity.sh` form a dev-prod parity smoke harness (exercises live
   Voyage / Qdrant / MinIO + the embed pipeline). Every objective signal says
   it is dead — see "Deadness evidence" below.

2. **CI composes flat in root.** The three genuinely-live CI composes
   (`ci`, `ci-local`, `ci-database`) sit in root next to the self-host file,
   with redundant `docker-compose.ci-` prefixes, adding to the visual noise.

## Goal

Root reads as a self-hosting guide. After this change root contains exactly two
compose files, both with self-explanatory names:

- `docker-compose.yml` — the self-host product (auto-discovered by `docker
  compose up`)
- `docker-compose.dev.yml` — the contributor local DB stack (`make dev-db-up`)

All CI composes move under `ci/`. The dead parity cluster is deleted entirely.

## Deadness evidence (parity cluster)

| Signal | Finding |
|---|---|
| In CI? | ❌ No workflow runs it. (The `elixir` hit in `verify.yml` was `elixir --short-version`, not the compose.) |
| Maintained? | ❌ `parity.validate.ex`'s last 4 touches are all tree-wide sweeps (#446 folders, #90/#70 `mix format`, #38 crypto) — never edited *for parity*. Last purpose-built commit was its creation. |
| Shell harness | ❌ `validate_parity.sh` untouched since #30. Hardcodes dead infra: `10.0.20.214:9768` (FastRaid MinIO), `10.0.20.201:6333` (SlowRaid Qdrant), `obsidian_notes_v2` collection, port 8000. |
| `parity.yml` | ❌ Last touched 2026-05-01 — a revert (#57). |
| Stale targets | ❌ Prod is AWS ECS now (FastRaid = staging); collection is `engram_notes` (config default in `config/dev.exs`, `config/test.exs`). The harness targets the entire pre-AWS, pre-`engram_notes` world. |
| Other callers? | ❌ `mix.exs` aliases don't reference it; nothing imports the task. Only the Makefile (7 targets) + 2 doc lines reference the cluster. |

**Nuance (intellectual honesty):** the Elixir task itself is *not* broken — all
five modules it calls still exist (`Engram.Embedders.Voyage`,
`Engram.Vector.Qdrant`, `Engram.Storage.S3`, `Engram.Indexing`,
`Engram.Workers.EmbedNote`). `make parity-mix` against a hand-pointed local
stack would plausibly still compile and run. But "could run if someone pointed
it locally" ≠ alive: no CI, no maintenance, no runbook invokes it, and its own
shell entrypoint fires at decommissioned hosts. Deadness is overdetermined.

`make backend-up` (the non-parity use of `elixir.yml` — "run the full app in
Docker locally") is already superseded by the canonical `docker-compose.yml`
self-host stack, so removing `elixir.yml` loses no capability.

## Decisions (locked during brainstorming)

### D1. Delete the parity cluster

Delete outright:

| File | Why |
|---|---|
| `docker-compose.elixir.yml` | Migration-era host for parity task; port 8000, no qdrant, superseded by `docker-compose.yml` |
| `docker-compose.parity.yml` | Voyage+s3 overlay for the parity harness; dead since 2026-05-01 |
| `lib/mix/tasks/parity.validate.ex` | The parity mix task; not in CI, unmaintained |
| `validate_parity.sh` | Shell parity harness; hardcodes decommissioned infra |

`.env.elixir` is **gitignored local working state** — not tracked, so it is not
part of the PR. Operator deletes it locally if desired (noted in PR body).

### D2. Remove the 7 dead Makefile targets

Drop these targets **and** their `.PHONY` entries:

- `backend-build`, `backend-up`, `backend-down` (used `docker-compose.elixir.yml`)
- `parity-mix`, `parity-bash`, `parity-ci-up`, `parity-ci-down`

`backend-up` is superseded by the self-host `docker-compose.yml`; if a
contributor wants the full app in Docker, `docker compose up -d` from root is
the path.

### D3. Relocate CI composes to `ci/` and drop the redundant prefix

Every reference path changes regardless, so renaming to drop the redundant
`docker-compose.ci-` prefix is free churn (same edit, cleaner target):

| Before (root) | After |
|---|---|
| `docker-compose.ci.yml` | `ci/compose.yml` |
| `docker-compose.ci-local.yml` | `ci/compose.local.yml` |
| `docker-compose.ci-database.yml` | `ci/compose.database.yml` |

`ci/compose.yml` is only ever invoked via explicit `-f`, so it never collides
with root auto-discovery (which only fires on a bare `docker compose` in a
directory containing `docker-compose.yml`/`compose.yaml`).

#### Build-context fix (the one real gotcha)

`ci.yml` and `ci-database.yml` each declare `build: { context: . }`. A compose
file's `context:` resolves **relative to that file's directory**, so after the
move `.` would point at `ci/` instead of repo root and the image build would
fail. Fix: change `context: .` → `context: ..` in both relocated files.

`ci-local.yml` is a pure env overlay (no `build:`, no relative paths) and moves
with zero internal edits. All three CI composes use **named volumes** (not bind
mounts), so there are no relative volume paths to adjust. The `name:` directives
(`engram-ci`, `engram-ci-db`) are location-independent, so project + container
names stay stable.

### D4. dev.yml stays at root

`docker-compose.dev.yml` is the contributor local Postgres+Qdrant stack
(`make dev-db-up`/`dev-selfhost`). It is *not* CI, so `ci/` is the wrong home.
Leaving it at root yields a root with two clearly-named composes (self-host +
dev) and all the confusing CI variants gone — which satisfies the goal directly
while minimizing reference churn. No internal edits (named volumes, no build).

## Reference update inventory

Paths that reference the relocated/removed files and must be updated. Impl must
re-grep at execution time (main moves), but the recon set is:

**Parity-cluster references (remove):**
- `Makefile` — 7 targets + `.PHONY` line
- `CLAUDE.md:75` — `docker compose -f docker-compose.elixir.yml up --build`
- `docs/context/encryption-operations.md:75` — `.env.elixir` dev-shell note

**CI-compose references (repath + rename):**
- `.github/workflows/verify.yml` — the heaviest consumer (`ci.yml` ×many,
  `ci-local.yml`, `ci-database.yml`); includes a fingerprint file-list line
  (~line 204) that names all three
- `Makefile` — `ci-up`, `ci-down`, `ci-e2e` targets
- `e2e/helpers/cleanup.py`
- `e2e/tests/api_only/test_72_free_signup_to_vault.py`,
  `test_74_cancel_to_free_overlimit.py`
- `docs/context/docker-build-cache-pitfalls.md`,
  `docs/context/e2e-vault-registration-diagnostics.md`
- `CLAUDE.md` — any `docker-compose.ci*` mentions
- `benchmarks/dataset/samples/*.jsonl` — **inspect, likely leave**: these are
  test corpus *data* that happens to contain the string, not invocations.

## Out of scope (explicit)

- `docker-compose.yml` (self-host) and `docker-compose.dev.yml` (dev) — untouched
  beyond confirming they stay at root.
- The 2026-06-05 self-host README/env work — already shipped; not revisited.
- Gitignored local working-state files (`.env`, `.env.elixir`, `erl_crash.dump`,
  `pytest-e2e.log`, `cover/`, `tmp/`) — not tracked; operator-local cleanup only,
  not part of this PR.
- No app-code behavior changes. The only `lib/` change is *deleting* one unused
  mix task.

## Acceptance criteria

1. Root contains exactly two compose files: `docker-compose.yml` and
   `docker-compose.dev.yml`. `ls docker-compose*.yml` shows only those two.
2. `ci/` contains exactly `compose.yml`, `compose.local.yml`,
   `compose.database.yml`.
3. `docker-compose.elixir.yml`, `docker-compose.parity.yml`,
   `lib/mix/tasks/parity.validate.ex`, `validate_parity.sh` are gone.
4. `git grep -nE 'parity\.validate|validate_parity|docker-compose\.(elixir|parity|ci|ci-local|ci-database)\.yml|\.env\.elixir' -- ':!docs/superpowers/'`
   returns nothing (all live references updated or removed).
5. The 7 dead Makefile targets + their `.PHONY` entries are gone;
   `make help` lists no `backend-*`/`parity-*` targets.
6. `docker compose -f ci/compose.yml config --quiet` exits 0 (build context
   resolves). Same for the `-f ci/compose.yml -f ci/compose.local.yml` overlay
   pair and for `ci/compose.database.yml`.
7. `mix compile --warnings-as-errors` succeeds (deleting the task leaves no
   dangling reference).
8. CI is green on the PR — in particular the `verify.yml` e2e jobs that drive
   the relocated CI composes pass end-to-end (proves the repath + `context: ..`
   fix actually works in the runner, not just `config`).

## Risks

- **`verify.yml` is the heaviest consumer and the real proof.** `config
  --quiet` validates locally, but only a green CI run proves the relocated
  build context + fingerprint file-list survive in the runner. Treat CI green
  as the acceptance gate, not local validation.
- **Fingerprint file-list (`verify.yml` ~line 204).** A no-op-push short-circuit
  hashes a named list of compose files. If that list isn't updated to the new
  paths, the fingerprint either breaks or silently stops tracking CI-compose
  changes. Impl must update it explicitly.
- **Build context.** Forgetting `context: .` → `context: ..` on either
  relocated build file makes CI image builds fail. Covered by AC#6 + AC#8.
- **Benchmark JSONL false positives.** Don't blindly sed the corpus files;
  inspect and almost certainly leave them.
- **Single PR.** Per workspace rule (`feedback_single_pr_all_changes`) the whole
  change ships as one PR; the steps below are commit boundaries inside one
  branch, not separate PRs.

## Implementation order (one concern per commit)

1. Delete parity-cluster files (`elixir.yml`, `parity.yml`,
   `parity.validate.ex`, `validate_parity.sh`).
2. Remove the 7 Makefile targets + `.PHONY` entries.
3. Scrub the 2 doc references (`CLAUDE.md:75`,
   `encryption-operations.md:75`).
4. `git mv` the 3 CI composes into `ci/` with new names; fix `context: .` →
   `context: ..` in `ci/compose.yml` + `ci/compose.database.yml`.
5. Update all CI-compose references (`verify.yml` incl. fingerprint list,
   Makefile `ci-*`, e2e helpers/tests, context docs).
6. Verify: `mix compile --warnings-as-errors`, `docker compose -f ci/compose.yml
   config --quiet` (+ overlay + database), `git grep` clean per AC#4.
7. Bump `mix.exs` version (one bump per PR, per
   `feedback_no_backend_version_bumps`).
8. Open PR; CI green is the acceptance gate.
