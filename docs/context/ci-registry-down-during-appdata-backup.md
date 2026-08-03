# `prebuild-ci-image` fails ~04:00-04:30 local: the nightly appdata backup stopped the registry

**Trigger:** CI fails with the image *built fine* and only the push failing:

```
The push refers to repository [10.0.20.214:5001/engram-ci]
Get "http://10.0.20.214:5001/v2/": dial tcp 10.0.20.214:5001: connect: connection refused
```

Every e2e job (`e2e-browser`, `e2e-crdt`, `e2e-clerk`, `headless-protocol`) then reports **skipping**, because they depend on that image. `record-pass` fails. The PR looks broken; nothing is wrong with the code.

## Cause

FastRaid (`10.0.20.214`) is Unraid, and the **Appdata Backup plugin** runs at **04:00 local**. It stops each container in turn, tars its appdata, and starts it again:

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

## Prevention

The fix is configuration, not code. In order of value:

1. **Exclude `local-ci-registry` from appdata backup.** It is 62G of *rebuildable* image layers — restoring it from a tarball is never the right recovery move (you re-push instead), so the backup buys nothing and costs a nightly CI outage plus ~90% of the backup window.
2. Failing that, move the 04:00 window off the hours when overnight/autonomous CI runs.

Separately: 62G suggests the registry has **no garbage collection** — CI images from every branch accumulating since the runner pool was built. Worth a `registry garbage-collect` pass and a retention policy regardless of the backup question.

Neither is done yet. Raise both before the next unattended overnight session.

## Related

- `runner-vm-setup.md` — the runners that push to this registry
- `ci-pipeline-gating.md` — which jobs gate, and what a `skipping` really means
- `fastraid-deploy.md` — the rest of the FastRaid host layout
