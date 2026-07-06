# Context Doc: `prebuild-mix` full recompile despite deps/`_build` cache hit

_Last verified: 2026-07-05_

## Status
Diagnosed. Fix implemented (mtime normalization), pending live-CI verification.

## What This Is
The `prebuild-mix` job in `.github/workflows/verify.yml` caches `deps/`, `_build/dev`, and `_build/test` via `actions/cache@v6`, keyed on `mix-deps-<BEAM_TAG>-<hash(mix.lock)>`. The intent (per the job's own comments and `docs/superpowers/plans/2026-06-29-lan-primary-ci-caching.md`) is that source-only changes recompile incrementally instead of from scratch. In practice, **every single run recompiled the entire codebase** (328/340 `.ex` files — essentially all of `lib/` + `test/support`), even when the cache step reported `Cache hit for: ...` / `Cache restored successfully` on all three caches.

## Environment
- `.github/workflows/verify.yml` — `prebuild-mix` job (~line 511).
- Self-hosted, isolated runner pool (`docs/context/runner-vm-setup.md`, workspace repo): 7 systemd-unit runners (`runner-1`..`runner-7`) on **one VM**, ephemeral JIT — `_work/` is wiped before every job, so there is never local-disk persistence between runs; `deps`/`_build` are always restored fresh from the LAN cache server (`GhaCacheServer`, replaces GitHub's hosted `actions/cache` backend for these runners).
- Elixir 1.17.3 / OTP 27.1.2 (host toolchain: OTP 27.3.4.11 — a different patch version, incidental, not the cause here).

## Root Cause

Mix's staleness check (`Mix.Compilers.Elixir`) is **`current_mtime > manifest_mtime`**, per source file — there is no content-hash fallback that forgives a bumped mtime on unchanged content. The compile manifest (`_build/{env}/lib/{app}/.mix/compile.elixir`) records, per module, the source file's mtime *as of the last successful compile*.

`actions/checkout` always writes every file with a fresh **"now"** mtime on checkout — git doesn't track or restore original commit mtimes. Meanwhile the cached `_build` (restored via `actions/cache`, a portable tar blob) carries the *old* mtimes from whenever it was last compiled — necessarily in the past. So on every run:

1. Checkout stamps every source file's mtime to "now".
2. `_build`/`deps` cache restores with old, pre-existing mtimes recorded in the compile manifest.
3. Mix compares `current_mtime (now) > manifest_mtime (old)` for literally every file → **every file is stale**, regardless of whether its content actually changed.
4. Staleness propagates through the compile-time dependency graph, so the result is a full recompile: `Compiling 328 files (.ex)` (`:dev`) / `Compiling 340 files (.ex)` (`:test`) — i.e. essentially all of `lib/` (320 files) + test support, every run.

This has **nothing to do with which runner** does the compile — it would happen even if the exact same runner ran two consecutive jobs, because `_work` is wiped (ephemeral JIT) and checkout *always* resets mtimes to "now" regardless of host. The cache-key computation, `restore-keys`, and the deps-vs-build split (`docs/superpowers/plans/2026-06-29-lan-primary-ci-caching.md`) are all working exactly as designed — the *restore* succeeds, but Mix's mtime-based staleness check discards it anyway.

**Correction from an earlier version of this doc:** an initial pass diagnosed this as Mix's compile manifest storing an *absolute source path* that differs across the runner pool's per-runner `_work` install directories (`actions-runner-runner-8` vs `actions-runner-runner-9`), and proposed fixing it by making the checkout path identical across runners (Docker bind-mount or runner reconfiguration). Deeper research into `Mix.Compilers.Elixir`'s actual algorithm (source path is stored **relative**, not absolute; the primary staleness signal is mtime, not path) showed the mtime mismatch alone fully explains the observed 100% full-recompile rate, independent of runner identity — so the path theory was, at minimum, not the dominant mechanism, and the much cheaper mtime fix was tried first. See `## Evidence` for what was actually measured.

## Evidence

Checked 7 recent `prebuild-mix` job runs across different branches (`gh run view --job <id> --log`):
- **100%** showed `Cache hit for: mix-deps-...` / `mix-build-dev-...` / `mix-build-test-...` (exact key match, not a `restore-keys` prefix fallback).
- **100%** of those same runs then logged `Compiling 328 files (.ex)` and `Compiling 340 files (.ex)` in the "Compile :dev and :test" step — i.e. the entire tree, not an incremental delta.
- `lib/` contains exactly 320 `.ex` files (`find lib -name "*.ex" | wc -l`), confirming 328/340 is "essentially everything," not a large-but-partial diff.

This is a **different** mechanism from `docs/context/docker-build-cache-pitfalls.md` (which covers the Dockerfile's own `--mount=type=cache` for the *Docker image* build in `prebuild-ci-image` — that build's `WORKDIR /app` is host-invariant by construction, so it doesn't hit this class of bug at all, mtime or path).

Not the same issue as merged PRs #804 (`fix/ci-prebuild-cache-and-log` — cold-compile on lockfile change + surfaced hidden compile errors) or #807 (`fix/ci-prebuild-compile-deps` — compile deps before app on cold `_build`). Those fixed real but separate bugs; this mtime issue predates and survives both.

## The Fix

Add a step right after `actions/checkout@v7` (before any `mix` command runs) that resets each source file's mtime to its actual last-commit time:

```bash
git ls-files -z -- lib test/support mix.exs mix.lock config \
  | xargs -0 -P 8 -I{} sh -c 'touch -d "@$(git log -1 --format=%ct -- "{}")" "{}"'
```

Scoped to the paths that actually affect `mix compile` staleness (`elixirc_paths` in `mix.exs` is `["lib"]` for `:dev`/`:prod`, `["lib", "test/support"]` for `:test`, plus `mix.exs`/`config/*.exs` which Mix tracks as compile-time config dependencies).

Why this works: files unchanged since the cached `_build` was compiled get their mtime reset to the SAME commit time the manifest already expects (or older) → not stale → skipped. Files genuinely changed in the current branch get a newer commit-time mtime → correctly recompiled. This preserves real incremental compilation instead of forcing a full rebuild every run.

Landed in `.github/workflows/verify.yml`'s `prebuild-mix` job only (scope decision — `unit-tests`/`lint`/`e2e-browser` also restore this cache and would likely benefit from the same one-line fix, but that's a follow-up, not bundled here to keep the change small and independently verifiable).

## Gotchas

- The `Cache hit` / `Cache restored successfully` log lines from `actions/cache` are **not proof of a fast incremental compile** for Elixir projects — they only prove the *bytes* round-tripped correctly. Mix's own staleness check is a separate, silent decision with no log line explaining *why* it recompiled everything (no warning is printed).
- Don't touch `_build`'s own mtime forward to "now" as a workaround — that would make Mix treat genuinely-changed files (this branch's real diff) as also up to date, silently running tests against stale compiled code. The fix must set *source* file mtimes to their real commit time, not blindly bump the build output's mtime.
- Mix's manifest ALSO tracks Elixir version, OTP version, and `MIX_ENV` as global invalidation triggers (a mismatch there forces a full recompile independent of mtime) — not the cause here (host and cache key both agree on OTP/Elixir version), but worth checking first if this class of bug recurs after a toolchain upgrade.
- `git log -1 --format=%ct -- <file>` runs once per file (~320 files); `xargs -P 8` parallelizes it to a few seconds. Not a bottleneck at this codebase size — revisit if `lib/` grows an order of magnitude.
- **`actions/checkout`'s default `fetch-depth: 1` (shallow clone) silently breaks this fix.** With only the tip commit in history, `git log -1 -- <file>` can't find a file's *true* last-modifying commit — it just returns the tip commit's own timestamp for every file that exists there (not an error, not empty — a plausible-looking but wrong answer). Since the tip commit is usually very recent, every file still ends up newer than the cached manifest and the whole tree recompiles anyway, with no error to signal the fix silently did nothing. Confirmed live: the first push with this fix (shallow checkout) still compiled all 320/332 files. Required `fetch-depth: 0` (full history) on the checkout step for the touch step to actually work.

## References
- `.github/workflows/verify.yml` — `prebuild-mix` job (~line 511-640).
- `docs/superpowers/plans/2026-06-29-lan-primary-ci-caching.md` — original caching design (cache-key split rationale).
- `docs/context/docker-build-cache-pitfalls.md` — the related-but-distinct Docker-layer cache pitfall in `prebuild-ci-image`.
- `docs/context/runner-vm-setup.md` (workspace repo) — runner pool topology (single VM, 7 ephemeral JIT runners, no persistent local disk state).
- PRs #804, #807 — prior, unrelated `prebuild-mix` caching fixes (cold-compile-on-lockfile-change; compile-deps-before-app ordering).
