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

**2. Writes to the GitHub cache backend from this pool are pathologically slow.**

Measured on `build-and-publish-image`, engram run 31057787877:

```
Cache Size: ~1153 MB (1209118098 B)
restore: 1m31s   -> ~13 MB/s   (download)
save:   14m00s   -> ~1.4 MB/s  (upload)
```

The earlier `deps/` + `_build` migration measured the same shape even worse
(~0.2 MB/s, a ~240 MB `_build` taking ~23 min/run), which is why those moved to
`runs-on/cache` against the FastRaid MinIO over LAN.

> **CORRECTION (2026-08-06).** The first version of this doc read that number as
> "~10 Mbps up in absolute terms" and blamed the site's uplink. **That was wrong,
> and it was an inference from CI timings rather than a measurement.** The link is
> fine. Measured single-stream upload, 50 MB random payload:
>
> | machine | |
> |---|---|
> | FastRaid host (runs the registry proxy) | 9.8 MB/s |
> | SlowRaid host | 12.5-16.1 MB/s |
> | FastRaid runner VM | 16.8-21.3 MB/s |
> | SlowRaid runner VM | 19.4 MB/s |
>
> RTT to ghcr.io is 52 ms with 0% loss, and `wmem_max` is 4 MB, so the TCP window
> ceiling is ~77 MB/s. Nothing in the network or the stack is the constraint.
>
> Do NOT reason about CI transfer times as if bandwidth were scarce here. Two real
> traps hide behind that assumption, and both were found only after the bad
> inference was discarded:
>
> 1. **`speedtest-cli` lies on this network.** It geolocates the FirstDigital IP to
>    the Pacific Northwest, picks a server ~1140 km away, and reports ~12 Mbps up.
>    Ignore it; measure against a known-close endpoint and check wall-clock.
> 2. **Summing per-stream `%{speed_upload}` across parallel curls overcounts**,
>    because streams finish at different times. Time the whole batch instead:
>    600 MB across 12 streams took 41s wall-clock (~117 Mbps aggregate).
>
> The GitHub-cache write path really is slow from here, which is why the fix below
> still stands. But the cause is on GitHub's side of the wire, not ours.

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

## The image push in the same job: a DIFFERENT bug, found by discarding the bad premise

The same job also pushed the image twice, GHCR 4m19s + ECR 5m33s, 149 MB each way, i.e.
**0.58 MB/s**. Under the "slow uplink" story that looked like the same problem and the
obvious fix was a cloud-side GHCR->ECR copy so the second upload never crossed the WAN.

That would have been building infrastructure to work around a misconfiguration.

The runner that pushed at 0.58 MB/s does **19.4 MB/s** on a plain upload — roughly 33x
faster. The actual cause: the runners' rootless dockerd sets
`HTTPS_PROXY=http://10.0.20.214:5000`, rpardini's **pull-through cache**, and only the
LAN registry was ever in `NO_PROXY`. So every push to ghcr.io and ECR was crossing a
proxy built for GETs, running on the slowest box in the rack.

Forcing a push through it reproduces the failure directly:

```
Error: pushing image ... HEAD .../manifests/err:
response did not include Docker-Content-Digest header
```

The same push direct: 100 MB in 7.07s (~14 MB/s). Fixed in homelab#16 by adding
`ghcr.io`, `pkg-containers.githubusercontent.com`, `.dkr.ecr.us-east-1.amazonaws.com`
and `.s3.us-east-1.amazonaws.com` to `NO_PROXY`. The blob hosts matter as much as the
registry hostnames: blob traffic redirects there, so a registry-only exemption still
sends the actual bytes through the proxy.

**The lesson worth keeping:** an unmeasured "the network is slow" premise made a
misconfiguration look like a law of physics, and pointed at building a whole copy
pipeline. Measure the host before designing around its supposed limits.
