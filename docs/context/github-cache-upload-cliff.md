# The GitHub-cache upload cliff on our self-hosted runners

**Symptom that sends you here:** a `Post <something> cache` step in CI takes 10-15
minutes, seemingly at random. Or: `build-and-publish-image` on a merge to main is
sometimes ~14 min, sometimes ~30 min, with no obvious difference in the diff.

## The two facts that explain it

**1. `Post Restore <name>` is the SAVE, not a teardown.**

`actions/cache` is one step plus an implicit post step. The post step is where the
upload happens, and it only runs when the key **missed** (an exact key hit means the
content is already stored, so there is nothing to save). So the duration of a
`Post ...` cache step is really a cache-hit indicator wearing a disguise:

| `Post Restore buildx cache` | means |
|---|---|
| ~1s | exact key hit, save skipped |
| 10-15 min | key missed, full payload uploaded |

That bimodality is why this hides. Most merges show 1s. Only the merges that roll the
key pay, so the average looks fine and the tail is brutal.

**2. This runner pool's uplink is asymmetric, and the GitHub cache backend is on the
wrong side of it.**

Measured on `build-and-publish-image`, engram run 31057787877:

```
Cache Size: ~1153 MB (1209118098 B)
restore: 1m31s   -> ~13 MB/s   (download)
save:   14m00s   -> ~1.4 MB/s  (upload)
```

Roughly a 10x asymmetry, and ~10 Mbps up in absolute terms. The earlier `deps/` +
`_build` migration measured the same thing even worse (~0.2 MB/s, a ~240 MB `_build`
taking ~23 min/run), which is why those moved to `runs-on/cache` against the FastRaid
MinIO over LAN at 200+ MB/s.

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
single `uses:` line moves both — but if you ever split a cache into separate
restore/save actions, they both have to be on the same backend.

## The trap this doc exists for

The buildx cache was deliberately **excluded** from the `deps/`+`_build` MinIO
migration, with a comment reading:

> buildx cache stays on actions/cache (separate Docker-layer concern).

That reasoning splits on **what the bytes are** (Docker layers vs compiled BEAM
artifacts). The constraint is **where the bytes go**. Docker layers do not travel over
a different uplink than `_build` does. Fixed in PR #1286; the 1.15 GB `mode=max` buildx
export now goes to MinIO like everything else.

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

Secondary tell: the GitHub cache quota is 10 GB/repo. Seven near-identical 1.15 GB
buildx entries were holding ~8 GB of it, which starves every other `actions/cache`
consumer in the repo through eviction.

## Not this doc's problem, but measured alongside it

The same job pushes the same image over the uplink twice: GHCR 4m19s (FastRaid staging
pulls `ghcr.io/engram-app/engram:${tag}`, plus self-host distribution) and ECR 5m33s
(what ECS deploys). The ECR leg re-uploads bytes that are already sitting in GHCR by
then. Fixing it needs a cloud-side registry copy so the transfer is GHCR->ECR rather
than homelab->ECR; a `crane copy` run from the homelab does NOT help, because the
bytes still transit the same uplink.
