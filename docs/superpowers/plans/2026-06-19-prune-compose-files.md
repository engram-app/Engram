# Prune Compose Clutter Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cut the engram repo root from 7 flat `docker-compose.*.yml` files to 2 (self-host + dev) by deleting the dead parity cluster and relocating the three live CI composes into `ci/`.

**Architecture:** Pure ops/docs refactor — no app behavior changes. The only `lib/` change is *deleting* one unused mix task. Deletions + `git mv` + reference repathing. Verification is command-driven (grep-clean, `compose config`, `mix compile`, CI green), not test-first — there is no new code to test.

**Tech Stack:** Docker Compose, GNU Make, GitHub Actions YAML, Elixir/Mix, conventional commits.

**Spec:** `docs/superpowers/specs/2026-06-19-prune-compose-files-design.md`

**Branch:** `chore/prune-compose-files` (worktree at `/home/open-claw/documents/code-projects/engram/.worktrees/prune-compose-files`, off `origin/main`)

> **Execute every command from the worktree root** (`.../engram/.worktrees/prune-compose-files`), not the `backend/` symlink. Makefile recipe lines are **tab-indented** — when editing the Makefile use the Edit tool and preserve the leading tab exactly.

---

## File Map

| File | Action | Why |
|---|---|---|
| `docker-compose.elixir.yml` | Delete | Parity-cluster host; superseded by `docker-compose.yml` |
| `docker-compose.parity.yml` | Delete | Parity overlay; dead since 2026-05-01 |
| `lib/mix/tasks/parity.validate.ex` | Delete | Parity mix task; not in CI, unmaintained |
| `validate_parity.sh` | Delete | Parity shell harness; hardcodes decommissioned infra |
| `Makefile` | Modify | Remove 7 dead targets (`backend-*`, `parity-*`) + `.PHONY`; repath `ci-up`/`ci-down` |
| `CLAUDE.md` | Modify | Remove the `docker-compose.elixir.yml` variant comment (line 76) |
| `docker-compose.ci.yml` | Move → `ci/compose.yml` | + `context: .`→`..`; repath internal comments |
| `docker-compose.ci-local.yml` | Move → `ci/compose.local.yml` | Pure overlay; repath internal comment |
| `docker-compose.ci-database.yml` | Move → `ci/compose.database.yml` | + `context: .`→`..`; repath internal comment |
| `.github/workflows/verify.yml` | Modify | Repath all CI-compose refs **incl. the fingerprint pathspec list (line ~204)** |
| `e2e/helpers/cleanup.py` | Modify | Repath comment ref |
| `e2e/tests/api_only/test_72_free_signup_to_vault.py` | Modify | Repath docstring ref |
| `e2e/tests/api_only/test_74_cancel_to_free_overlimit.py` | Modify | Repath docstring ref |
| `docs/context/docker-build-cache-pitfalls.md` | Modify | Repath prose refs |
| `docs/context/e2e-vault-registration-diagnostics.md` | Modify | Repath prose ref |
| `mix.exs` | Modify | Version bump `0.5.461` → `0.5.462` |

**Out of scope (do NOT touch):** `docker-compose.yml`, `docker-compose.dev.yml`, `benchmarks/dataset/samples/*.jsonl` (corpus data, not invocations), gitignored local state (`.env.elixir`, `erl_crash.dump`, etc.).

> **Note on the spec's reference inventory:** the spec listed a second doc scrub at `docs/context/encryption-operations.md`. On the current branch (`origin/main`) that file has **no** `.env.elixir` reference — the line existed on older history only. Confirmed via `git grep`. There is nothing to change there; `CLAUDE.md:76` is the only doc-comment scrub.

---

## Task 1: Delete the parity cluster

**Files:**
- Delete: `docker-compose.elixir.yml`, `docker-compose.parity.yml`, `lib/mix/tasks/parity.validate.ex`, `validate_parity.sh`

- [ ] **Step 1: Confirm only the cluster itself + the Makefile reference these (no surprise importer)**

Run:
```bash
git grep -nE 'Parity\.Validate|parity\.validate' -- ':!docs/superpowers/' ':!lib/mix/tasks/parity.validate.ex'
```
Expected: only `Makefile:118` and `Makefile:119` (those targets are removed in Task 2). If anything under `lib/` or `test/` appears, STOP — there is a real caller the spec missed; surface it before deleting.

- [ ] **Step 2: Delete the four files**

```bash
git rm docker-compose.elixir.yml docker-compose.parity.yml lib/mix/tasks/parity.validate.ex validate_parity.sh
```

- [ ] **Step 3: Verify the task is gone and the tree still compiles**

```bash
ls docker-compose.elixir.yml docker-compose.parity.yml lib/mix/tasks/parity.validate.ex validate_parity.sh 2>&1
mix compile --warnings-as-errors 2>&1 | tail -5
```
Expected: the `ls` reports all four as "No such file or directory"; `mix compile` finishes with no errors and no warning about a missing/undefined `Parity.Validate` module. (Deleting a `Mix.Task` module is safe — nothing `import`s or `alias`es it.)

- [ ] **Step 4: Commit**

```bash
git add -A
git commit -m "chore: delete dead dev-prod parity cluster

Removes docker-compose.elixir.yml, docker-compose.parity.yml,
lib/mix/tasks/parity.validate.ex, and validate_parity.sh. Not run in CI,
unmaintained since creation, and validate_parity.sh hardcodes decommissioned
infra (FastRaid/SlowRaid IPs, obsidian_notes_v2). See spec for full evidence.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Remove the 7 dead Makefile targets

**Files:**
- Modify: `Makefile` (`.PHONY` line 1; delete `backend-*` block ~54-61 and `parity-*` block ~117-128)

- [ ] **Step 1: Trim the `.PHONY` list**

Run:
```bash
sed -i 's/ backend-build backend-up backend-down//; s/ parity-mix parity-bash parity-ci-up parity-ci-down//' Makefile
```

Verify:
```bash
grep -nE '^\.PHONY' Makefile
```
Expected: the line no longer contains `backend-build`, `backend-up`, `backend-down`, `parity-mix`, `parity-bash`, `parity-ci-up`, or `parity-ci-down`. It still contains `dev`, `ci-up`, `ci-down`, `ci-e2e`, `gen-master-key`, etc.

- [ ] **Step 2: Delete the `backend-*` target block**

Use the Edit tool to remove this exact block (recipe lines are tab-indented), including the trailing blank line so it doesn't leave a double gap before `# --- Frontend ---`:

```
backend-build:     ## Build engram_elixir docker image
	docker compose -f docker-compose.elixir.yml build engram_elixir

backend-up:        ## Start full Elixir stack (Phoenix + Postgres + Qdrant)
	docker compose -f docker-compose.elixir.yml up -d --wait

backend-down:      ## Stop Elixir stack
	docker compose -f docker-compose.elixir.yml down

```

- [ ] **Step 3: Delete the `parity-*` block (including its section header)**

Use the Edit tool to remove this exact block (tab-indented recipes):

```
# --- Parity Validation ---

parity-mix:        ## Run mix parity.validate (internal module validation)
	env $$(grep -v '^\#' .env.elixir | grep -v '^$$' | xargs) mix parity.validate

parity-bash:       ## Run validate_parity.sh (deployed system validation)
	VOYAGE_API_KEY=$${VOYAGE_API_KEY} bash validate_parity.sh

parity-ci-up:      ## Start CI stack in parity mode (requires VOYAGE_API_KEY)
	VOYAGE_API_KEY=$${VOYAGE_API_KEY} docker compose -f docker-compose.ci.yml -f docker-compose.parity.yml -p engram-ci up -d --build --wait

parity-ci-down:    ## Tear down parity CI stack
	docker compose -f docker-compose.ci.yml -f docker-compose.parity.yml -p engram-ci down -v --remove-orphans
```

- [ ] **Step 4: Verify no `elixir`/`parity` residue and the Makefile still parses**

```bash
grep -nE 'backend-build|backend-up|backend-down|parity-|docker-compose\.elixir\.yml|docker-compose\.parity\.yml' Makefile
make help >/dev/null && echo "make help OK"
```
Expected: first command prints nothing; `make help OK` prints (Makefile parses, no orphaned recipe). The only remaining `docker-compose.ci.yml` refs in the Makefile are the `ci-up`/`ci-down` recipes — those get repathed in Task 5.

- [ ] **Step 5: Commit**

```bash
git add Makefile
git commit -m "chore(make): drop dead backend-* and parity-* targets

backend-up was already superseded by the canonical docker-compose.yml
self-host stack; the parity targets drove the just-deleted parity cluster.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Scrub the `CLAUDE.md` elixir-variant comment

**Files:**
- Modify: `CLAUDE.md` (line 76)

- [ ] **Step 1: Remove the stale comment line**

Use the Edit tool to delete exactly this line:

```
# docker-compose.elixir.yml is a lighter variant (Elixir + PostgreSQL + MinIO, no Qdrant/Ollama)
```

The surrounding `docker compose up --build` block stays — only the one comment line referencing the deleted file is removed.

- [ ] **Step 2: Verify**

```bash
grep -n 'docker-compose.elixir.yml' CLAUDE.md
```
Expected: no output.

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs(claude): drop reference to deleted docker-compose.elixir.yml

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Relocate the three CI composes into `ci/`

**Files:**
- Move: `docker-compose.ci.yml` → `ci/compose.yml`
- Move: `docker-compose.ci-local.yml` → `ci/compose.local.yml`
- Move: `docker-compose.ci-database.yml` → `ci/compose.database.yml`
- Modify (post-move): `ci/compose.yml`, `ci/compose.database.yml` (build context); all three (internal comment repath)

- [ ] **Step 1: Create the folder and move + rename**

```bash
mkdir -p ci
git mv docker-compose.ci.yml          ci/compose.yml
git mv docker-compose.ci-local.yml    ci/compose.local.yml
git mv docker-compose.ci-database.yml ci/compose.database.yml
```

- [ ] **Step 2: Fix the build context in the two files that build (`context: .` → `context: ..`)**

After the move, `context: .` would resolve to `ci/` instead of repo root. Run:
```bash
sed -i 's|^      context: \.$|      context: ..|' ci/compose.yml ci/compose.database.yml
```

Verify exactly one fixed context per file:
```bash
grep -nE '^      context: \.\.$' ci/compose.yml ci/compose.database.yml
grep -nE '^      context: \.$' ci/compose.yml ci/compose.database.yml
```
Expected: the first command prints one `context: ..` line for each file; the second command prints nothing (no bare `context: .` left). `ci/compose.local.yml` has no `build:` block — correct, leave it.

- [ ] **Step 3: Repath the relocated files' own internal comments**

The header/usage comments inside the moved files still say the old names. Run:
```bash
sed -i \
  -e 's#docker-compose\.ci-database\.yml#ci/compose.database.yml#g' \
  -e 's#docker-compose\.ci-local\.yml#ci/compose.local.yml#g' \
  -e 's#docker-compose\.ci\.yml#ci/compose.yml#g' \
  ci/compose.yml ci/compose.local.yml ci/compose.database.yml
```

Verify no old names remain inside the moved files:
```bash
grep -nE 'docker-compose\.ci' ci/compose.yml ci/compose.local.yml ci/compose.database.yml
```
Expected: no output.

- [ ] **Step 4: Validate compose still resolves (build context + YAML)**

`docker compose config` interpolates env and errors on required (`:?`) vars, so provide a dummy:
```bash
ENCRYPTION_MASTER_KEY=dummy docker compose -f ci/compose.yml config --quiet && echo "ci OK"
ENCRYPTION_MASTER_KEY=dummy docker compose -f ci/compose.yml -f ci/compose.local.yml config --quiet && echo "ci+local OK"
ENCRYPTION_MASTER_KEY=dummy docker compose -f ci/compose.database.yml config --quiet && echo "ci-db OK"
```
Expected: each prints its `... OK` line (exit 0). If `config` complains about another unset required var, set it inline too (e.g. `FOO=x ENCRYPTION_MASTER_KEY=dummy ...`) — a named-var error is a config success at the YAML/context level. The authoritative proof is CI (Task 8).

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "refactor(ci): move CI composes into ci/ and drop redundant prefix

docker-compose.ci{,-local,-database}.yml -> ci/compose{,.local,.database}.yml.
Fixes build context (. -> ..) in the two files that build, since context now
resolves relative to ci/. Root keeps only the self-host + dev composes.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Repath all external references

**Files:**
- Modify: `.github/workflows/verify.yml`, `Makefile`, `e2e/helpers/cleanup.py`, `e2e/tests/api_only/test_72_free_signup_to_vault.py`, `e2e/tests/api_only/test_74_cancel_to_free_overlimit.py`, `docs/context/docker-build-cache-pitfalls.md`, `docs/context/e2e-vault-registration-diagnostics.md`

By now the parity/backend Makefile lines are gone (Task 2), so the only surviving CI-compose refs are live ones to repath. The pattern `docker-compose\.ci\.yml` (dot after `ci`) will NOT match `ci-local`/`ci-database`, but apply the specific patterns first anyway for safety.

- [ ] **Step 1: Apply the repath across all consumers**

```bash
sed -i \
  -e 's#docker-compose\.ci-database\.yml#ci/compose.database.yml#g' \
  -e 's#docker-compose\.ci-local\.yml#ci/compose.local.yml#g' \
  -e 's#docker-compose\.ci\.yml#ci/compose.yml#g' \
  .github/workflows/verify.yml \
  Makefile \
  e2e/helpers/cleanup.py \
  e2e/tests/api_only/test_72_free_signup_to_vault.py \
  e2e/tests/api_only/test_74_cancel_to_free_overlimit.py \
  docs/context/docker-build-cache-pitfalls.md \
  docs/context/e2e-vault-registration-diagnostics.md
```

- [ ] **Step 2: Verify the fingerprint pathspec list was repathed (the silent-failure risk)**

`verify.yml` hashes a `git ls-tree` pathspec list to short-circuit no-op pushes. If those pathspecs don't point at the moved files, the fingerprint stops covering CI-compose changes — silently.

```bash
grep -nE 'ci/compose\.(yml|local\.yml|database\.yml)' .github/workflows/verify.yml | grep -E 'ls-tree|compose\.yml compose|compose\.local'
sed -n '204p' .github/workflows/verify.yml
```
Expected: line 204 now reads (paths only):
```
              ci/compose.yml ci/compose.local.yml ci/compose.database.yml \
```

- [ ] **Step 3: Verify the Makefile `ci-up`/`ci-down` recipes were repathed**

```bash
grep -nE 'ci-up:|ci-down:' -A1 Makefile
```
Expected: both recipes now invoke `docker compose -f ci/compose.yml -p engram-ci ...`.

- [ ] **Step 4: Global verification — zero stale refs anywhere tracked**

```bash
git grep -nE 'docker-compose\.(elixir|parity|ci|ci-local|ci-database)\.yml|\.env\.elixir|parity\.validate|validate_parity' -- ':!docs/superpowers/' ':!benchmarks/dataset/samples'
```
Expected: **no output.** (The spec/plan docs and the benchmark corpus are intentionally excluded — the corpus contains the string as data, not as an invocation; confirm with `git grep -l 'docker-compose.ci' benchmarks/dataset/samples` if curious, and leave it untouched.)

- [ ] **Step 5: Commit**

```bash
git add -A
git commit -m "chore: repath CI-compose references to ci/compose*.yml

Updates verify.yml (incl. the git ls-tree fingerprint pathspec list),
Makefile ci-up/ci-down, e2e helpers/tests, and two context docs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Full local verification gate

**Files:** none modified (verification only).

- [ ] **Step 1: Root has exactly two composes; `ci/` has exactly three**

```bash
ls docker-compose*.yml
echo "---"
ls ci/
```
Expected:
```
docker-compose.dev.yml
docker-compose.yml
---
compose.database.yml
compose.local.yml
compose.yml
```

- [ ] **Step 2: Tree compiles clean**

```bash
mix compile --warnings-as-errors 2>&1 | tail -3
```
Expected: compiles, no errors/warnings.

- [ ] **Step 3: All three compose invocations resolve**

```bash
ENCRYPTION_MASTER_KEY=dummy docker compose -f ci/compose.yml config --quiet && echo OK1
ENCRYPTION_MASTER_KEY=dummy docker compose -f ci/compose.yml -f ci/compose.local.yml config --quiet && echo OK2
ENCRYPTION_MASTER_KEY=dummy docker compose -f ci/compose.database.yml config --quiet && echo OK3
```
Expected: `OK1`, `OK2`, `OK3`.

- [ ] **Step 4: `make help` lists no removed targets**

```bash
make help | grep -E 'backend-|parity-' && echo "FAIL: stale target" || echo "OK: no stale targets"
```
Expected: `OK: no stale targets`.

- [ ] **Step 5: No commit (verification only).** If any check fails, fix in the relevant task before proceeding.

---

## Task 7: Version bump

**Files:**
- Modify: `mix.exs` (version line)

Per `feedback_no_backend_version_bumps`: one bump per PR, at PR-open time. Operator-facing change (Makefile + compose layout), so the pre-push hook expects it.

- [ ] **Step 1: Read current version**

```bash
grep -nE '^\s*version:' mix.exs
```
Expected: `      version: "0.5.461",` (if different, bump that patch by 1 instead).

- [ ] **Step 2: Bump `0.5.461` → `0.5.462`**

Use the Edit tool: change `      version: "0.5.461",` to `      version: "0.5.462",`.

- [ ] **Step 3: Verify + commit**

```bash
grep -nE '^\s*version:' mix.exs
git add mix.exs
git commit -m "chore: bump version 0.5.461 -> 0.5.462

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
Expected: `version: "0.5.462",`.

---

## Task 8: Push + open PR (CI green is the acceptance gate)

**Files:** none modified.

- [ ] **Step 1: Push the branch**

```bash
git push -u origin chore/prune-compose-files
```

- [ ] **Step 2: Open the PR**

```bash
gh pr create \
  --title "chore: prune compose clutter — delete parity cluster, move CI composes to ci/" \
  --body "$(cat <<'EOF'
## Summary

Root went from **7 flat `docker-compose.*.yml` files → 2** (self-host + dev).

- **Deleted the dead parity cluster:** `docker-compose.elixir.yml`,
  `docker-compose.parity.yml`, `lib/mix/tasks/parity.validate.ex`,
  `validate_parity.sh` — not run in CI, unmaintained since creation, and the
  shell harness hardcoded decommissioned infra (FastRaid/SlowRaid IPs,
  `obsidian_notes_v2`). Full deadness evidence in the spec.
- **Removed 7 dead Makefile targets:** `backend-build/up/down`,
  `parity-mix/bash/ci-up/ci-down`. `backend-up` was already superseded by the
  canonical `docker-compose.yml`.
- **Moved the 3 live CI composes into `ci/`** and dropped the redundant prefix:
  `docker-compose.ci{,-local,-database}.yml` → `ci/compose{,.local,.database}.yml`.
  Fixed `build.context` (`.` → `..`) in the two that build. Repathed every
  consumer incl. the `verify.yml` `git ls-tree` fingerprint pathspec list.

Root now reads as a self-hosting guide: `docker-compose.yml` (the product) +
`docker-compose.dev.yml` (contributor DB stack).

## Spec / Plan
- `docs/superpowers/specs/2026-06-19-prune-compose-files-design.md`
- `docs/superpowers/plans/2026-06-19-prune-compose-files.md`

## Test plan
- [x] `mix compile --warnings-as-errors` clean (no dangling parity task ref)
- [x] `docker compose -f ci/compose.yml config` + `-f ci/compose.yml -f ci/compose.local.yml` + `-f ci/compose.database.yml` all resolve (build context fixed)
- [x] `git grep` shows zero stale `docker-compose.{elixir,parity,ci*}.yml` / `parity.validate` / `.env.elixir` refs (excl. spec + benchmark corpus)
- [ ] **CI green — the real gate.** The `verify.yml` e2e jobs drive the relocated CI composes end-to-end; only a green run proves the repath + `context: ..` fix hold in the runner.

## Notes
- `.env.elixir` is gitignored local working state — delete locally if you like; not part of this PR.
- `benchmarks/dataset/samples/*.jsonl` mention the old filename as corpus *data*, not invocations — intentionally untouched.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Watch CI**

```bash
gh pr checks --watch
```
Expected: all checks green. **If any e2e job fails on a compose path or build context, that is the repath/context fix not holding — triage before merge; do not merge red.**

---

## Self-review (completed by plan author)

- **Spec coverage:** D1 (delete cluster) → Task 1; D2 (Makefile targets) → Task 2; D3 (relocate + rename + context fix) → Task 4; D3 references incl. fingerprint → Task 5; D4 (dev.yml stays) → enforced by File Map "out of scope" + Task 6 Step 1 assertion. All acceptance criteria map to Task 6 + Task 8.
- **Spec correction folded in:** the spec's `encryption-operations.md` scrub does not apply on this branch (no `.env.elixir` ref present) — documented in the File Map note; not a task.
- **Placeholder scan:** none — every edit shows exact text/commands.
- **Consistency:** target filenames (`ci/compose.yml`, `ci/compose.local.yml`, `ci/compose.database.yml`) and the sed patterns are identical across Tasks 4, 5, and 6.
