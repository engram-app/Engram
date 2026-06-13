# Context Doc: Docker Build Cache Pitfalls

_Last verified: 2026-04-18_

## Status
Working — current Dockerfile compiles and releases in one RUN step without the `_build` cache mount.

## What This Is
How the backend Dockerfile packages an Elixir release, and why the old split-step design produced stale beam files in CI.

## Environment
- `backend/Dockerfile` — multi-stage Elixir release build.
- Triggered by `docker-compose.ci.yml` (self-hosted runner on FastRaid) and any local `docker compose -f docker-compose.ci.yml build`.
- Cache mounts are BuildKit-scoped (`id=mix-deps`, `id=mix-build` historically) — persistent named volumes on the builder host, survive across runs.

## The Pitfall

**Symptom:** a fixed bug appears to still be present in CI. Stacktrace line numbers point to code that no longer exists at that line in the current source. `mix compile --force` output shows files being compiled, but the released app behaves like the old source.

**Root cause:** the Dockerfile used to split compilation into two RUN steps that both mounted the same `_build` cache volume:

```dockerfile
# OLD — DO NOT REINTRODUCE
RUN --mount=type=cache,target=/app/_build,id=mix-build \
    mix compile --force

RUN --mount=type=cache,target=/app/_build,id=mix-build \
    mix release && cp -r /app/_build/prod/rel/engram /app/_release
```

`mix compile --force` wrote fresh beams into the cache volume. `mix release` in the next RUN step mounted the same cache volume — but BuildKit's layer caching + the persistent cache meant the release step sometimes packaged stale beams that had been written by an earlier build. `--force` in the compile step did not help because the stale files lived in the release step's view of `_build/prod/rel/`, which `mix release` generated from whatever it saw in the cache.

Cache-busting the layer hash (editing the Dockerfile top, adding comments, changing copy paths) had **no effect** — cache mounts persist independently of layer hashes.

## The Fix

Merge compile and release into a single RUN step and drop the `_build` cache mount entirely. Only `deps` is cached; `_build` is regenerated every build.

```dockerfile
RUN --mount=type=cache,target=/app/deps,id=mix-deps \
    mix compile --force && \
    mix release && \
    cp -r /app/_build/prod/rel/engram /app/_release
```

The extra ~1 minute of compile time is worth the guarantee that the released image matches the committed source.

## Key Commands / Patterns

- Verify a CI build is using fresh code: check the stack log for `Image cache miss (engram-ci:<sha>) — building` AND `Compiling N files (.ex)` AND look for expected file-level compilation output.
- If a stacktrace line number disagrees with current source, **suspect build cache first, not code**. `git show HEAD -- <file>` to confirm the commit has the change; if yes, it is a deployment/cache issue, not a source issue.
- Local test: `docker compose -f docker-compose.ci.yml build --no-cache engram` forces a full rebuild without BuildKit cache.

## Failed Approaches / Dead Ends

1. **Cache-bust by editing Dockerfile top.** Layer-hash invalidation does not clear mounted cache volumes. No effect.
2. **`rm -rf /app/_build/prod/lib/engram` before `mix compile --force`.** Purges beams in the compile-step's view, but the release step mounts the cache independently and may see unrelated stale files. No effect.
3. **Adding comment-only changes to the Dockerfile to force layer rebuild.** Same as #1 — does not touch cache-mount contents.

## Gotchas

- `_build` cache mounts are a footgun for any multi-step build that both writes to and reads from `_build` across RUN steps. Keep them within a single RUN or remove entirely.
- BuildKit cache mount IDs (`id=mix-build`) are shared across repositories on the same runner. A different project's build could theoretically pollute the mount — one more reason to avoid `_build` caching.
- When debugging, `gh run view --log` truncates BuildKit output. Use `gh run download` and inspect `ci-*-stack.log` for the full build log.
- The only safe cache for Elixir releases is `deps` (compiled dependencies). App beams must be rebuilt from source every time.
- **Cross-runner image distribution (2026-06-13):** the `engram-ci:<hash>` image the `prebuild-ci-image` job builds is NOT visible to other runners just because they're "on the same VM" — the isolated pool is multi-host (runner-1..runner-N), each with its own docker daemon. The original design `docker tag`'d the image locally and the e2e jobs ran `up --no-build`; when prebuild and the e2e consumer landed on different hosts, compose found no local image, tried to pull bare `engram-ci:<hash>` from Docker Hub, got `pull access denied / No such image`, and the backend container never started — surfacing as EVERY e2e test erroring with `Connection refused` to the API. Fix: prebuild pushes `${LOCAL_REGISTRY}/engram-ci:<hash>` to the FastRaid registry (:5001, the same one the ci-pass markers use) and the e2e bring-up steps `docker pull` it first. Symptom to recognize in `docker-compose.log`: it's EMPTY (engram never ran) and `ci-*-stack.log` shows `No such image: engram-ci:<hash>`.

## References

- `backend/Dockerfile` — the fix landed in commit `7d8d636` on `feat/pluggable-key-providers`.
- `docs/context/e2e-debugging.md` (workspace repo) — older dead-end theory around `_build` cache that was NOT the same issue but was a related symptom.
- BuildKit cache mount docs: https://docs.docker.com/build/cache/optimize/#use-cache-mounts
