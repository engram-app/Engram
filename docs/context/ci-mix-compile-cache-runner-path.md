# Context Doc: `prebuild-mix` full recompile despite a `_build` cache hit

_Last verified: 2026-10-03_

## The trap
The `prebuild-mix` job in `.github/workflows/verify.yml` restores `deps/`,
`_build/dev` and `_build/test` (via `runs-on/cache` to LAN MinIO). Before this
fix, every run still recompiled essentially all of `lib/` + `test/support`, even
on an exact cache hit.

## Root cause
The Mix compile manifest stores the **absolute project root**. Decoded
`_build/dev/lib/engram/.mix/compile.elixir`: element 6 of the tuple is the
literal path. CI runners check out at different absolute `_work` paths, and a
job rarely lands on the runner that saved the cache. Mix sees a different
project root, invalidates the whole manifest, and recompiles everything.

## The fix
Run every `mix` command inside a container bind-mounted at a fixed `/app`
(`docker run -v "$PWD:/app" -w /app`). A bind mount is a real mountpoint, so
`getcwd()` returns `/app` on every runner. A symlink does not work: `getcwd()`
resolves through it to the unstable real path.

Details that matter:
- **Builder image.** `MIX_BUILDER_IMAGE` is the same `hexpm/elixir` tag the
  release Dockerfile pins. The bare image has no C toolchain (`bcrypt_elixir`
  fails with `"make" not found`), so the job builds a derived
  `engram-mix-builder:ci` with `build-essential`, `git`, hex and rebar baked in.
- **Use the bare Docker Hub tag, not `:5001`.** The `:5001` registry only holds
  the `engram-ci` images CI pushes itself. Docker Hub pulls already go through
  the `:5000` pull-through cache.
- **Resolve the OTP/Elixir tag inside the container.** The cache key must match
  what compiles. The host toolchain is a different OTP patch.

Scope: only `prebuild-mix` is docker-wrapped. `unit-tests`, `lint` and
`e2e-browser` restore the same cache bare-metal.

### The mtime-normalize step is vestigial
`prebuild-mix` also resets each source file's mtime to its last-commit time
(which is why it checks out with `fetch-depth: 0`). That step does nothing
useful. On Elixir 1.17 Mix uses mtime only to pick files to re-hash, then
compares content digests. Touching every source to "now" recompiles 0 files
(re-measured 2026-10-03 on 1.17.3 / OTP 27). The workflow comment claiming
"no content-hash fallback" is wrong. See [ci-fingerprint-markers.md](ci-fingerprint-markers.md).

## Gotchas
- `Cache hit` / `Cache restored successfully` only proves the bytes
  round-tripped. Mix's manifest-validity check is separate and silent.
- Decode the manifest before trusting a summary of Mix internals:
  `elixir -e 'IO.inspect(:erlang.binary_to_term(File.read!("_build/dev/lib/<app>/.mix/compile.elixir")), limit: :infinity)'`
- The manifest also invalidates on an Elixir/OTP version change. Check that
  first after a toolchain bump.
- Do not touch `_build` mtimes forward to "now" to dodge staleness. Mix would
  then treat changed files as up to date.
- Keying the cache by `runner.name` defeats same-run sharing: consumers land on
  different runners than the producer.

## References
- `.github/workflows/verify.yml`, `prebuild-mix` job
- [docker-build-cache-pitfalls.md](docker-build-cache-pitfalls.md): a different
  cache pitfall in the Docker image build (`WORKDIR /app` is host-invariant there)
- `../engram-workspace/docs/context/runner-vm-setup.md`: runner pool topology
