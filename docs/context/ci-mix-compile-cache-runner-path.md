# Context Doc: `prebuild-mix` full recompile despite deps/`_build` cache hit

_Last verified: 2026-07-05_

## Status
**Fixed and verified live 2026-07-05.** Confirmed on a real CI run: cache produced on `runner-7`, restored and reused on `runner-2` (a different runner) with **zero files recompiled** (no `Compiling N files` line at all, just `Generated engram app`) — job runtime dropped from ~4-6.5 minutes (full recompile every run) to 45 seconds.

## What This Is
The `prebuild-mix` job in `.github/workflows/verify.yml` caches `deps/`, `_build/dev`, and `_build/test` via `actions/cache@v6`, keyed on `mix-deps-<BEAM_TAG>-<hash(mix.lock)>`. The intent (per the job's own comments and `docs/superpowers/plans/2026-06-29-lan-primary-ci-caching.md`) is that source-only changes recompile incrementally instead of from scratch. In practice, **every single run recompiled the entire codebase** (328/340 `.ex` files — essentially all of `lib/` + `test/support`), even when the cache step reported `Cache hit for: ...` / `Cache restored successfully` on all three caches.

## Environment
- `.github/workflows/verify.yml` — `prebuild-mix` job (~line 511).
- Self-hosted, isolated runner pool (`docs/context/runner-vm-setup.md`, workspace repo): 7 systemd-unit runners (`runner-1`..`runner-7`) on **one VM**, ephemeral JIT — `_work/` is wiped before every job, so there is never local-disk persistence between runs; `deps`/`_build` are always restored fresh from the LAN cache server (`GhaCacheServer`, replaces GitHub's hosted `actions/cache` backend for these runners). Each runner installs at its own path, e.g. `/home/runner/actions-runner-runner-5/_work/Engram/Engram`, `/home/runner/actions-runner-runner-1/_work/Engram/Engram` — jobs land on whichever runner is free, essentially at random.
- Elixir 1.17.3 / OTP 27.1.2 (host toolchain: OTP 27.3.4.11 — a different patch version, incidental).

## Root Cause (ground-truth confirmed)

Decoded a real compile manifest directly (`elixir -e 'IO.inspect(:erlang.binary_to_term(File.read!("_build/dev/lib/engram/.mix/compile.elixir")))'`) rather than relying on secondhand descriptions of Mix internals. The manifest is an 11-element tuple; **element 6 is the absolute project root path** (e.g. `"/home/open-claw/documents/code-projects/engram"`), stored verbatim.

Combined with checkout always stamping a fresh "now" mtime on every file (git doesn't preserve commit mtimes), the failure mode is:

1. `_build`/`deps` cache restores fine (exact key match — confirmed `Cache hit for: ...` on every run checked).
2. The restored manifest's embedded project-root path was recorded by whichever runner originally produced it (e.g. `runner-5`'s `_work/Engram/Engram`).
3. **This run almost never lands on that same runner** (7-runner pool, effectively random scheduling) — its own checkout root is a *different* absolute path (e.g. `runner-1`'s `_work/Engram/Engram`).
4. Mix sees the manifest's recorded project root doesn't match the current one and invalidates the whole manifest, forcing a full recompile of every module — regardless of per-file mtimes.

This is **independent of the mtime issue** (checkout resetting mtimes to "now" is also real and also forces staleness on its own) — the two combine, and fixing only one is not sufficient. Confirmed live: a full-history (`fetch-depth: 0`) + per-file `git log`-based mtime fix, verified working (correct historical timestamps applied, no errors), **still produced a full recompile** (320/332 files) on a run that landed on a different runner than the one that saved the cache. The absolute-path invalidation dominates independently of mtime correctness.

## Evidence

- Checked 7 `prebuild-mix` job runs pre-fix across different branches: 100% exact-key `Cache hit`, 100% then logged `Compiling 328 files (.ex)` / `Compiling 340 files (.ex)` (`lib/` has exactly 320 `.ex` files — confirms "essentially everything," not a partial diff).
- **Live test 1** (mtime fix only, shallow checkout — `fetch-depth: 1` default): `Compiling 320 files (.ex)` / `332 files (.ex)`. Root cause: shallow clone means `git log -1 -- <file>` only sees the tip commit, so every file resolved to that one (recent) timestamp instead of its true last-change time — the touch script ran (no error) but was silently a no-op in effect.
- **Live test 2** (mtime fix with `fetch-depth: 0` fixed, confirmed correct per-file historical timestamps applied): **still** `Compiling 320 files (.ex)` / `332 files (.ex)`. Run 1 landed on `runner-5`; run 2 landed on `runner-1` — different absolute checkout paths, matching the manifest decode finding.
- Direct manifest decode (see Root Cause) is the conclusive evidence: element 6 of the `compile.elixir` manifest tuple is the literal absolute project root string.
- **Live test 3** (Docker-wrap, bare `hexpm/elixir` image, no build tools): failed — `bcrypt_elixir` NIF dependency errored with `"make" not found in the path`. Fixed by building a small derived image (`engram-mix-builder:ci`) with `build-essential`/`git`/hex/rebar baked in.
- **Live test 4** (Docker-wrap + build-essential, first run under the new container-based cache key): `Compiling 320 files (.ex)` / `332 files (.ex)` — expected, this was a genuine cold-cache miss (the cache key changed: OTP/erts is now queried from inside the container, `erts15.1.2`, not the host's `erts15.2.7.8`). Cache saved successfully at the end.
- **Live test 5 (the real test)**: a second run against that freshly-saved cache. Producer run landed on `runner-7`; this run landed on `runner-2` — a genuinely different runner. Result: **zero files compiled** (`Cache hit for: ...` on all three caches, then only `Generated engram app`, no `Compiling N files` line at all). Job runtime: 45 seconds (`02:45:00` → `02:45:45`), down from ~4-6.5 minutes. This conclusively confirms the fix.

This is a **different** mechanism from `docs/context/docker-build-cache-pitfalls.md` (the Dockerfile's own `--mount=type=cache` for the *Docker image* build in `prebuild-ci-image` — that build's `WORKDIR /app` is host-invariant by construction, so it never hits this class of bug).

Not the same issue as merged PRs #804 (`fix/ci-prebuild-cache-and-log`) or #807 (`fix/ci-prebuild-compile-deps`). Those fixed real but separate bugs; this one predates and survives both.

## The Fix

Two parts, both landed in `prebuild-mix` only (scope decision — `unit-tests`/`lint`/`e2e-browser` also restore this cache and would benefit from the same treatment, but that's a follow-up; extending Docker-wrapping there adds real complexity, e.g. `mix test` needing Postgres over `localhost` → `--network host`).

**1. Mtime normalization** (real, but not sufficient alone — keep it, it's still correct):
```bash
git ls-files -z -- lib test/support mix.exs mix.lock config \
  | xargs -0 -P 8 -I{} sh -c 'touch -d "@$(git log -1 --format=%ct -- "{}")" "{}"'
```
Requires `fetch-depth: 0` on the checkout step — shallow clone (`fetch-depth: 1`, the default) makes `git log -1 -- <file>` return the tip commit for every file instead of each file's true last-change commit, silently defeating the fix.

**2. Docker-wrap the compile** (the fix that actually matters — addresses the absolute-path invalidation):

Run `mix local.hex`/`mix local.rebar`/`mix deps.get`/`mix deps.compile`/`mix compile` inside `MIX_BUILDER_IMAGE` (the same `hexpm/elixir:1.17.3-erlang-27.3.4.14-debian-bookworm-20260623-slim` the release Dockerfile pins), bind-mounted via `docker run -v "$PWD:/app" -w /app`. A bind mount is a real mountpoint (unlike a symlink, which Erlang's `getcwd()` resolves through to the real, unstable path) — `/app` resolves identically via `getcwd()` on every runner, so the compile manifest's embedded project root is always the same string regardless of which of the 7 runners lands the job. This is exactly the mechanism that already makes `prebuild-ci-image` immune to this bug.

**Reference the bare Docker Hub tag, not the `:5001` LAN registry mirror.** The `:5001` `LOCAL_REGISTRY` only actually holds the `engram-ci` images this workflow builds and pushes itself — `hexpm/elixir` was never pushed there despite `.github/setup-runner.sh` appearing to do so (confirmed live: pulling `10.0.20.214:5001/hexpm/elixir:...` failed with `manifest unknown`). Docker Hub pulls on this runner pool already transparently route through a caching proxy at `:5000` (`docs/context/runner-vm-setup.md` Gotcha #6), so the bare tag is both correct and already cache-accelerated — it's the same tag `prebuild-ci-image` pulls successfully via the Dockerfile's own `BUILDER_IMAGE` arg.

Rootless Docker is available to the `runner` exec user without sudo (confirmed in `docs/context/runner-vm-setup.md`), so no runner-side privilege changes are needed.

**The bare `hexpm/elixir` image has no C toolchain.** `bcrypt_elixir` (a NIF dependency) failed live with `"make" not found in the path` — the release Dockerfile's builder stage installs `build-essential` before its own `mix` commands for exactly this reason. Fixed by building a small derived image once per job (`engram-mix-builder:ci`, `FROM ${MIX_BUILDER_IMAGE}` + `apt-get install build-essential git` + `mix local.hex --force && mix local.rebar --force` baked in) and using that tag for `Fetch deps`/`Compile` instead of the bare image directly. This also means `mix local.hex`/`mix local.rebar` don't need to rerun on every `docker run` invocation, and no separate hex/rebar cache volumes are needed.

The "Resolve OTP/Elixir version" step also had to move inside the container (`docker run --rm "$MIX_BUILDER_IMAGE" sh -c '...'` instead of querying the host's `erl`/`elixir`) — the cache key must reflect what's actually compiling now, not the separately-installed host toolchain (which is a different OTP patch version, 27.3.4.11 vs the image's 27.1.2).

**Rejected alternatives** (tried or considered first, in order):
- *Symlink to a fixed path*: doesn't work — Erlang's `getcwd()` resolves through symlinks to the real path, so Mix would still see the unstable one.
- *Key the cache by `runner.name`*: technically stable, but defeats the job's actual purpose — `unit-tests`/`lint`/`e2e-browser` need to reuse `prebuild-mix`'s compile within the *same* CI run, and they land on different runners than `prebuild-mix` most of the time (7-runner pool). Scoping per-runner would make that same-run sharing rarely hit.
- *Reconfigure each runner's `_work` directory to an identical literal path*: the textbook-correct fix (mirrors the `GIT_CLONE_PATH` pattern from the reference blog below), but genuinely can't work while runners share a host and run concurrently with a literal shared path — would need per-job mount namespaces to give 7 processes an identical-looking path without colliding, which doesn't survive across GH Actions' separate step invocations cleanly. Docker's bind mount achieves the same isolation more simply, reusing Docker's own namespace machinery instead of hand-rolling one.

## Gotchas

- The `Cache hit` / `Cache restored successfully` log lines from `actions/cache` are **not proof of a fast incremental compile**. They only prove the *bytes* round-tripped. Mix's own staleness/manifest-validity check is separate and silent — no log line explains *why* it recompiled everything.
- **Don't trust secondhand summaries of Mix's compiler internals over decoding a real manifest.** An earlier pass here concluded (based on a research query) that Mix's manifest stores only relative source paths and the primary staleness signal is mtime alone, with no path-sensitivity. Decoding an actual `.mix/compile.elixir` file directly proved that wrong for the project-root field (element 6 is a literal absolute path). If this class of bug recurs, decode the manifest first: `elixir -e 'IO.inspect(:erlang.binary_to_term(File.read!("_build/dev/lib/<app>/.mix/compile.elixir")), limit: :infinity)'`.
- Don't touch `_build`'s own mtime forward to "now" as a workaround for the mtime half of this — that would make Mix treat genuinely-changed files as also up to date, silently running tests against stale compiled code.
- Mix's manifest also tracks Elixir/OTP version as invalidation triggers — a mismatch there forces a full recompile independent of everything else. Not the cause here (host and container agree closely enough for testing purposes), but worth checking first if this bug class recurs after a toolchain bump.
- `git log -1 --format=%ct -- <file>` runs once per file (~320 files); `xargs -P 8` parallelizes it to under a second even with full history. Not a bottleneck at this codebase size.

## References
- `.github/workflows/verify.yml` — `prebuild-mix` job (~line 511-670).
- `docs/superpowers/plans/2026-06-29-lan-primary-ci-caching.md` — original caching design (cache-key split rationale).
- `docs/context/docker-build-cache-pitfalls.md` — the related-but-distinct Docker-layer cache pitfall in `prebuild-ci-image`.
- `docs/context/runner-vm-setup.md` (workspace repo) — runner pool topology (single VM, 7 ephemeral JIT runners, no persistent local disk state, rootless Docker available to the `runner` user).
- External: https://ananthakumaran.in/2022/08/26/elixir-ci-cache.html — documents the `GIT_CLONE_PATH`-style fix (identical checkout path across CI machines) this doc's Docker-bind-mount approach achieves without touching runner registration.
- PRs #804, #807 — prior, unrelated `prebuild-mix` caching fixes (cold-compile-on-lockfile-change; compile-deps-before-app ordering).
