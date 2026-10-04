# Context Doc: Docker Build Cache Pitfalls

_Last verified: 2026-10-03_

## What This Is
How the backend `Dockerfile` packages an Elixir release, and why the app
compile and `mix release` must share one RUN step with no `_build` cache mount.

## The Pitfall

**Symptom:** a fixed bug still appears in CI. Stacktrace line numbers point at
code that is no longer at that line. `mix compile --force` output shows files
compiling, but the released app behaves like the old source.

**Root cause:** compile and release used to be two RUN steps that both mounted
the same `_build` cache volume:

```dockerfile
# OLD — DO NOT REINTRODUCE
RUN --mount=type=cache,target=/app/_build,id=mix-build \
    mix compile --force

RUN --mount=type=cache,target=/app/_build,id=mix-build \
    mix release && cp -r /app/_build/prod/rel/engram /app/_release
```

The release step could package stale beams left in the persistent cache by an
earlier build. Cache mounts persist independently of layer hashes, so
cache-busting the Dockerfile (comments, reordering) has **no effect**.

## The Fix

The final app compile and release are one RUN step with no `_build` mount. It
also runs `mix deps.get` first, to reconcile the shared `mix-deps` mount to this
image's `mix.lock`:

```dockerfile
RUN --mount=type=cache,target=/app/deps,id=mix-deps,sharing=locked \
    ... \
    mix deps.get --only $MIX_ENV && \
    mix compile --force && \
    mix release && \
    cp -r /app/_build/prod/rel/engram /app/_release
```

The earlier `mix deps.compile` step does still mount `id=mix-build` at
`/app/_build`. That is safe because it only compiles deps; app beams are never
read from the mount. Keep it that way.

## Gotchas

- If a stacktrace line number disagrees with current source, suspect the build
  cache before the code. Confirm the commit has the change with `git show`.
- But prove the container really runs old code before blaming the cache. Check
  the server-side log (`docker-compose.log`), not just the job log. In 2026-04 a
  suspected stale-beam was really a Clerk quota 403 in the test process.
- BuildKit cache mount IDs (`id=mix-build`) are shared across every build on the
  same builder host.
- `gh run view --log` truncates BuildKit output. Use `gh run download` and read
  `*-stack.log` for the full build log.
- Local full rebuild: `docker compose -f ci/compose.yml build --no-cache engram`.

## References

- `Dockerfile`: the compile+release RUN step and its comment
- `Engram.SpaIntegrity`: boot-time guard against a release whose `index.html`
  references assets that are not on disk
- BuildKit cache mounts: https://docs.docker.com/build/cache/optimize/#use-cache-mounts
