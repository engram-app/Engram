# `prebuild-ci-image` fails Mondays ~04:00: the appdata backup stopped the registry

> **FIXED 2026-08-03** — `LocalCIRegistry` now has `skip: yes` + `dontStop: yes`
> in the plugin config, matching the `DockerRegistry` entry that was already
> there. Kept as a diagnosis record, and because the same shape recurs for any
> container the backup stops.

**Trigger:** CI fails with the image *built fine* and only the push failing:

```
The push refers to repository [10.0.20.214:5001/engram-ci]
Get "http://10.0.20.214:5001/v2/": dial tcp 10.0.20.214:5001: connect: connection refused
```

Every e2e job (`e2e-browser`, `e2e-crdt`, `e2e-clerk`, `headless-protocol`) then reports **skipping**, because they depend on that image. `record-pass` fails. The PR looks broken; nothing is wrong with the code.

## Cause

FastRaid (`10.0.20.214`) is Unraid, and the **Appdata Backup plugin** runs **weekly on Mondays at 04:00 local** (`backupFrequency: weekly`, `backupFrequencyWeekday: 1` in `/boot/config/plugins/appdata.backup/config.json` — it is NOT nightly). It stops each container in turn, tars its appdata, and starts it again:

```
04:00  php /usr/local/emhttp/plugins/appdata.backup/scripts/backup.php
04:05  tar -c -z -f /mnt/main-pool/appdata-backups/ab_<date>/LocalCIRegistry.tar.gz \
                    /mnt/cache/appdata/local-ci-registry
```

`LocalCIRegistry` serves `:5001`. While its tar runs, the port is dead and any CI push fails.

## How to recognise it (vs a real registry problem)

```bash
ssh root@10.0.20.214 'docker inspect LocalCIRegistry \
  --format "policy={{.HostConfig.RestartPolicy.Name}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}"'
# policy=unless-stopped exit=2 oom=false restarts=0
```

`restarts=0` under `unless-stopped` is the tell: **Docker treats it as deliberately stopped.** `unless-stopped` does not auto-restart a container that something ran `docker stop` on, so a crash-looping registry would show a non-zero `RestartCount` and a real fault would usually show `oom=true` or a full volume. Confirm with:

```bash
ssh root@10.0.20.214 'ps aux | grep -iE "appdata|backup|tar " | grep -v grep'
```

A live `tar ... LocalCIRegistry.tar.gz` line is the smoking gun. Several unrelated containers showing `Up N minutes` at the same moment is the corroborating signal — that is the plugin working its way down the list.

## Do NOT start the container

`docker start LocalCIRegistry` while its tar is running:

1. corrupts that night's backup — the registry writes into the directory `tar` is mid-read on, so the archive captures a torn state, and
2. fights the plugin, which starts the container itself when the tar finishes.

**Wait it out.** Poll until it returns, then re-run the failed job:

```bash
until ssh root@10.0.20.214 'docker ps --filter name=LocalCIRegistry --filter status=running -q' | grep -q .; do sleep 60; done
gh run rerun <run-id> --failed
```

## How long the outage lasts

Longer than you would guess, because this container is the whole backup:

```
/mnt/cache/appdata/local-ci-registry      62G      <- CI image layers
next largest (stable-diffusion)          434M
GitCdn                                   165M
AdGuard-Home                              64M
```

Measured 2026-08-03: `:5001` went down at **04:05** and answered again at **04:56** — a **51-minute** outage from one container's tar. Every other container in the run finished in about a minute. Any CI push landing in that window fails, so an overnight or autonomous session will hit it.

## The fix that was applied

`/boot/config/plugins/appdata.backup/config.json` had **no entry at all** for
`LocalCIRegistry`, so it fell through to the defaults and got stopped + tarred.
`DockerRegistry`, `Qdrant`, `Lancache` and `ollama` already had entries opting
out — the policy existed, this container just predated nothing and was simply
never added.

Added, copied verbatim from the `DockerRegistry` entry:

```json
"LocalCIRegistry": {
    "skip": "yes",      // don't back it up: 62G of rebuildable layers
    "dontStop": "yes",  // and don't stop it: this is what broke CI
    "group": "", "backupExtVolumes": "no", "updateContainer": "",
    "exclude": "", "skipBackup": "no", "verifyBackup": "",
    "ignoreBackupErrors": ""
}
```

`dontStop` is the load-bearing half. `skip` alone would still stop the
container during the run.

Backup of the previous config: `config.json.bak-20260803-claude`.

## Registry size and why GC alone will not help

Measured 2026-08-03:

```
blobs/                                    63G     <- all of it
repositories/  (all 10, metadata only)   ~220M
engram-ci                                827 tags
ci-pass                                  752 tags
```

One full app image is pushed per CI run and nothing ever prunes them.

**A plain `registry garbage-collect` reclaims essentially nothing here:**

```
11582 blobs marked, 5 blobs and 0 manifests eligible for deletion
```

GC only removes blobs no manifest references, and every one of those 827
manifests is still *tagged*. The lever is therefore **tag retention**, not GC —
GC is only the second step, after old tags stop referencing their manifests.

Also note `storage.delete.enabled` is **not set** in the registry config, so the
DELETE API is refused; either enable it (`REGISTRY_STORAGE_DELETE_ENABLED=true`)
or remove the tag directories under
`repositories/engram-ci/_manifests/tags/<tag>` and let
`garbage-collect --delete-untagged` sweep the now-unreferenced manifests.

### Do it in a quiet window

The distribution docs are explicit that a blob uploaded *while* GC runs can be
deleted out from under the pusher. Stop the registry (or set it read-only) and
confirm no CI is in flight first:

```bash
gh run list --limit 15 --json status --jq '.[] | select(.status!="completed")'
```

Everything in this registry is rebuildable, so the worst case is CI redoing
work — but an in-flight run failing for a reason nobody can reproduce is worse
than a slow one.

Tracked as engram-app/Engram#1224. Deliberately NOT done as a one-off: at
~1-2G per CI run a manual prune just resets the clock, and there is no disk
pressure to justify hand-surgery (`/mnt/cache` is 1.5T of 5.0T). It wants a
scheduled retention policy or nothing.

## Related

- `runner-vm-setup.md` — the runners that push to this registry
- `ci-pipeline-gating.md` — which jobs gate, and what a `skipping` really means
- `fastraid-deploy.md` — the rest of the FastRaid host layout
