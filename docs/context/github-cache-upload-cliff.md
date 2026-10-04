# The GitHub-cache upload cliff on our self-hosted runners

**Symptom that sends you here:** a `Post <something> cache` step in CI takes 10-15
minutes, seemingly at random. Or: `build-and-publish-image` on a merge to main is
sometimes ~14 min, sometimes ~30 min, with no obvious difference in the diff.

## The two facts that explain it

**1. `Post Restore <name>` is the SAVE, not a teardown.**

`actions/cache` is one step plus an implicit post step. The post step is where the
upload happens, and it only runs when the key **missed**. So the duration of a
`Post ...` cache step is a cache-hit indicator:

| `Post Restore buildx cache` | means |
|---|---|
| ~1s | exact key hit, save skipped |
| 10-15 min | key missed, full payload uploaded |

Most merges show 1s. Only merges that roll the key pay, so the average looks fine
and the tail is brutal.

**2. Writes to the GitHub cache backend from this pool are pathologically slow.**

A 1.15 GB buildx save took 14 min (~1.4 MB/s) against a 1.5 min restore. The
earlier `deps/` + `_build` saves were worse (~0.2 MB/s).

The site's link is not the cause. Measured single-stream upload from the runner
VMs is 17-21 MB/s. The slow side is GitHub's cache write path. Measure the host
before designing around a supposed bandwidth limit; `speedtest-cli` picks a far
server here and under-reports.

## The rule

**Nothing large belongs on the GitHub cache backend from these runners.** Use
`runs-on/cache` (SHA-pinned fork of `actions/cache`, same API) so the payload goes to
LAN MinIO instead of GitHub's Azure Blob store.

```yaml
uses: runs-on/cache@88d90644011a3a9957fd141a106f5a94f9794203 # v5.0.7
```

Keep that pin identical across every call site. The runner injects the S3 config via
its environment, so no secret appears in the workflow, and absent that env the action
falls back to the default GitHub cache.

**Restore and save must move together.** An S3 save paired with a GitHub restore is a
guaranteed permanent miss. Because they are one action plus its post step, swapping the
single `uses:` line moves both. If you split a cache into separate restore/save
actions, both must be on the same backend.

## The trap this doc exists for

The buildx cache was once deliberately left on `actions/cache` as a "separate
Docker-layer concern". That splits on **what the bytes are**. The constraint is
**where the bytes go**. Fixed in PR #1286; the 1.15 GB `mode=max` buildx export now
goes to MinIO like everything else.

If you find yourself justifying a cache staying on the GitHub backend because of what
kind of data it holds, that is this same mistake. The only question is payload size.

## Diagnosing a suspected instance

```bash
# Step timings for a job, including the post steps
gh api "repos/engram-app/engram/actions/runs/<RUN_ID>/jobs?per_page=100" \
  --jq '.jobs[] | select(.name|test("<JOB>")) |
        .steps[] | "\(.name): \(.started_at) -> \(.completed_at)"'

# Cache entry sizes + when each was written (created_at == when a save finished)
gh api "repos/engram-app/engram/actions/caches?per_page=100" \
  --jq '.actions_caches[] | "\(.key)  \(.size_in_bytes/1048576|floor)MB  \(.created_at)"'
```

Compare a run whose key rolled against one whose key did not. If the `Post` step is 1s
on one and minutes on the other, you have found this.

Secondary tell: the GitHub cache quota is 10 GB/repo. A few near-identical 1 GB+
entries evict every other `actions/cache` consumer in the repo.

## Image pushes: keep push hosts out of the proxy

The runners' rootless dockerd sets `HTTPS_PROXY=http://10.0.20.214:5000`, a
pull-through cache built for GETs. Pushes routed through it crawl (0.58 MB/s
observed) or fail with `response did not include Docker-Content-Digest header`.
Every push target must be in `NO_PROXY`: the registry hostnames **and** their blob
hosts, because blob traffic redirects there. Today that is `ghcr.io`,
`pkg-containers.githubusercontent.com`, `.dkr.ecr.us-east-1.amazonaws.com` and
`.s3.us-east-1.amazonaws.com` (homelab#16). Adding a new push target means adding
its hosts too.
