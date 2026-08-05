# CI fingerprint markers — how job skipping stays honest

How `verify.yml` decides a job can skip, and the one invariant that makes it
safe. Read this before adding a "fast mode" to any fingerprinted job, or
before widening a cache restore-key.

Companion to [ci-pipeline-gating.md](ci-pipeline-gating.md) (what gates vs
reports) and [ci-mix-compile-cache-runner-path.md](ci-mix-compile-cache-runner-path.md).

## The mechanism

`ci/fingerprint/groups.sh` defines **content groups** (`elixir-src`,
`unit-tests`, `priv`, `docker-image`, `lint-config`, `e2e-harness`,
`frontend`, `ci-meta`). Each group hashes `git ls-tree -r HEAD -- <paths>`,
which emits blob SHAs — so the hash is pure tracked-content, stable across
rebases and squashes.

`ci/fingerprint/compute.sh` maps each job to a **superset** of groups and
hashes them together into one `job_hash`. When a job passes, it pushes an
empty image tagged `ci-<job>:<hash>` to the FastRaid registry
(`ci/fingerprint/record.sh`). A later run that computes the same hash finds
the marker and skips the job.

The store is the **FastRaid Docker registry, not `actions/cache`** — chosen
deliberately, because `actions/cache` scopes entries to the writing ref, so a
PR's marker would be invisible to the `main` push that squash-merges it. The
registry is ref-agnostic: a squash-merge preserves the tree, so main computes
the same hash and replays the branch's proof.

## THE INVARIANT

> A marker means **this job ran to FULL success for this exact content.**

Everything else follows from it. Two ways to break it:

**1. Under-hashing.** If a job reads a file that is in none of its groups, a
stale marker skips the check that file was supposed to trigger. Config files
are the dangerous case because they fail **open** — a loosened rule rides in
silently and permanently.

Two such gaps were live until 2026-08-05: `openapi.json` (the OpenAPI drift
gate) and `.squawk.toml` (squawk's cwd-discovered config), both read by
`unit-tests`, both in no group. `groups_test.sh` now carries a static
input-coverage assertion — add a pair there whenever a job step starts reading
a new path.

**2. Reduced modes.** If a job can pass while doing *less* work, its marker
lies. `record-job-markers` therefore refuses to seed when
`e2e-target-suite` is set (a `pytest -k` subset must never seed a full-hash
e2e marker), and `mix test --stale` was **removed** for the same reason.

If you add a fast path to a fingerprinted job, you must either exclude that
run from marker seeding, or fold the mode into the hash.

## Why `--stale` was removed (2026-08-05)

It never narrowed anything. Measured: 4081 tests under `--stale` vs 4081 on
main for the identical tree.

Root cause was not ExUnit — the `_build` cache key stopped at the mix.lock
hash, and `actions/cache` does not re-save on an exact hit. So `_build` was
written once, on the first run after the lockfile moved, then frozen.
mix.lock had not changed in 114 commits, so every run restored a
114-commit-stale tree; with `use`-macro fan-out (Phoenix/Ecto) that
recompiled ~all 355 lib files, making every test a stale compile-dependent.

Fixed by putting the commit SHA in the `_build` key so every run saves a
fresh build, with a **lockfile-scoped** restore-key prefix for fallback.

> Do NOT widen that prefix to beam-only. A restore across a mix.lock change
> reuses a `_build` compiled against different deps and crashes protocol
> consolidation (`FunctionClauseError` in `:elixir_erl.dynamic_form/1`). The
> lockfile hash in the prefix is what prevents it.

Also verified and rejected: normalizing source mtimes in the consumers.
`prebuild-mix` has such a step and it is **vestigial** — on Elixir 1.17,
touching every source to `now` recompiles 0 files, because the compiler
compares content digests and only uses mtime to pick what to re-hash. Adding
it (plus the `fetch-depth: 0` it needs) is pure cost.

## main is not special any more

`is-full` used to include `refs/heads/main`, pinning every `skip-<job>` to
false. That defeated the ref-agnostic marker store on the exact push it was
built for: ~61 main pushes/week re-deriving what the branch had proved.

Now `is-full` means only the nightly schedule, `[ci-full]`, and
`force_full`. main runs anything whose hash **missed** — that is the real
safety net. Measured effect on a main push: **28 → 5 runner-minutes.**

Two things still key on main explicitly, not via `is-full`:

- **Targeted-e2e suppression** (`IS_MAIN`), so a squash-merge whose body still
  carries the branch's `[e2e: ...]` tag cannot narrow main's e2e matrix.
- **`build-and-publish-image`**, which is about deployable bytes, not tests.

## What content hashing cannot model

`mix_audit` is time-dependent: the same `mix.lock` yields a different verdict
once a new CVE is published. No content hash can express that. The 06:00 UTC
nightly is a genuine full run and bounds the exposure at 24h. This is an
accepted limit, documented inline at the `lint` job — do not "fix" it by
disabling lint skipping.

## Gotchas

- `ci-meta` (`.github/workflows/verify.yml` + `ci/fingerprint`) is in **every**
  job's group list, so any CI change busts every hash and forces a full run.
  A PR editing `verify.yml` therefore validates itself — and its markers seed
  the merge, which is why main can skip immediately after such a PR lands.
- `record()` seeds only on `result == "success"`. A **skipped** job reports
  `skipped`, not `success`, so it cannot re-seed a marker it did not earn.
- `migration-gates` is deliberately never marker-skipped: it has early `exit 0`
  success paths that return green without running the rollforward.
- Marker hashes come from the fingerprint job via `MARKER_HASH`, never
  recomputed on the recording runner (which may not have BEAM on PATH).
