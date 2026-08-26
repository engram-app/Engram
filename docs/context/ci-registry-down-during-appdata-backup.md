# `prebuild-ci-image` fails Mondays ~04:00: the appdata backup stopped the registry

> **FIXED 2026-08-03 (half of it) — COMPLETED 2026-08-23.** `dontStop: yes` did
> work: the registry stopped going down on Mondays, so CI stopped breaking. But
> `skip: yes` silently did nothing, and the backup kept tarring 57G of live
> registry every week. See [The `skip` trap](#the-skip-trap) — the working key is
> **`skipBackup`**, now set. Kept as a diagnosis record, and because the same
> shape recurs for any container the backup stops.

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

<a id="the-skip-trap"></a>

## The `skip` trap — why that config looked right and wasn't (2026-08-23)

The entry above reads as "don't back it up, don't stop it". Only the second
half was true. Every Monday for the next three weeks the plugin still spent
**32 minutes tarring the 57G registry while it was running**, tar reported

```
tar: /mnt/cache/appdata/local-ci-registry/docker/registry/v2/repositories/ci-pass/_manifests/tags: file changed as we read it
```

and the whole run was marked `-failed`. CI was fine — `dontStop` held — so
nothing pointed back here.

**`skip` is only honoured for containers listed in `containerOrder`.** From
`ABHelper.php::sortContainers()`:

```php
foreach ($order as $name) {                          // $order = containerOrder
    $containerSettings = $abSettings->getContainerSpecificSettings($name, $removeSkipped);
    if ($containerSettings['skip'] == 'yes' && $removeSkipped) {
        unset($_containers[$name]);                  // <- the only place skip is read
        continue;
    }
    ...
}
return array_merge($sortedContainers, $_containers); // <- unknown containers, unchecked
```

`containerOrder` is a 58-name list written when you hit Save on the settings
page. `LocalCIRegistry` and `minio` were both created *after* the last save, so
neither is in it, so the loop never sees them, so `skip` is never read and they
fall straight through the `array_merge` into the backup.

This is why `Lancache` and `JinaReranker` — same `skip: yes` — *are* correctly
excluded, and the debug log shows `Not adding Lancache to sorted containers:
should be ignored` for them but nothing at all for `LocalCIRegistry`. Same
setting, opposite outcome, purely because of list membership.

### Use `skipBackup`, not `skip`

`skipBackup` is checked inside `backupContainer()`, which runs for every
container regardless of order:

```php
if ($containerSettings['skipBackup'] == 'yes') {
    self::backupLog("Should NOT backup this container at all. Only include it in stop/start. Skipping backup...");
```

Applied 2026-08-23 (`config.json.bak-20260823-claude`):

```json
"LocalCIRegistry": {
    "skipBackup": "yes",          // the one that actually gates the tar
    "dontStop": "yes",            // still load-bearing: this is what broke CI
    "skip": "yes",                // harmless, but do NOT rely on it
    "ignoreBackupErrors": "no",   // was "yes" — a bandaid added 2026-08-17 04:39
    "group": "", "backupExtVolumes": "no", "updateContainer": "",
    "exclude": "", "verifyBackup": ""
}
```

`ignoreBackupErrors: yes` had been added minutes after the 2026-08-17 failure.
It mutes the alert and changes nothing else — the 32 minutes and 47G still get
spent. Removed.

**Rule of thumb:** to keep a container out of the backup, set `skipBackup`. Only
trust `skip` for a container you know is in `containerOrder`, and re-saving the
settings page is what puts it there.

### The knock-on: retention stops, and `-failed` dirs are immortal

A failed run short-circuits cleanup — `backup.php`:

```
An error occurred during backup! RETENTION WILL NOT BE CHECKED!
```

So three weeks of failures meant zero pruning. Worse, the retention pass cannot
parse its own failure-suffixed directory names and keeps them "to be safe":

```php
$backupDate = date_create_from_format("??_Ymd_His", $correctedItem);
if (!$backupDate) { $toKeep[] = $backupItem; continue; }   // Better safe than sorry
```

```
php > date_create_from_format("??_Ymd_His", "ab_20260817_030002-failed");  // false
php > date_create_from_format("??_Ymd_His", "ab_20260810_040002");         // 2026-08-10
```

`-failed` dirs are therefore **never** deleted by the plugin. Cleared by hand on
2026-08-23: 1 on FastRaid (188G), 6 on SlowRaid going back to April (83G) —
**271G**. Worth checking for these whenever a backup has been red for a while.

### `minio` had the same shape

Also missing from `containerOrder`, and holding `gha-cache` — 110G of Actions
buildx cache, 95 minutes of tar plus 19 minutes of verify, retained ×7. The
bucket is **not** growing unbounded: it has a working 14-day ILM expiry and sits
at a steady ~110G / 835 objects. It simply never belonged in a backup. Excluded
by path rather than skipping the container, because the other minio buckets
(`engram-*-attachments`) are real data:

```json
"minio": { "exclude": "/mnt/cache/appdata/minio/gha-cache", ... }
```

`exclude` becomes `tar --exclude '<abs path>'`. Verified on the host — the
minio tar went from 95 minutes to **1.5 seconds**, still capturing the
attachment buckets and the 25K of `.minio.sys/buckets/gha-cache` metadata that
carries the ILM rule (you want that back on a restore).

### Same trap, different host

SlowRaid's `media-preview-generator` mounts Plex's live appdata `rw`. The backup
stopped only that container, Plex kept writing, tar hit the same `file changed
as we read it`. Also absent from `containerOrder`, also "fixed" with `skip: yes`.
Now `skipBackup: yes` — and its 13G of Plex data was a duplicate of `plex.tar.gz`
anyway.

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

`storage.delete.enabled` is **not set**, but that turns out not to matter:
it gates the HTTP DELETE *API*, not the CLI. `registry garbage-collect` deletes
blobs through the storage driver regardless — verified 2026-08-03. So the recipe
is: remove tag directories under `repositories/engram-ci/_manifests/tags/<tag>`,
then `garbage-collect --delete-untagged` sweeps the now-unreferenced manifests.

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

## Done: scheduled retention (2026-08-03)

Source of truth is **`ci/prune-ci-registry.sh`** in this repo — it sits beside
`ci/fingerprint/`, which writes the markers it expires, so the two retention
windows stay in step. It is copied up to the FastRaid host and wired into
`/etc/cron.d/root` by the User Scripts plugin, **Sundays 05:00**:

```
0 5 * * 0 .../startCustom.php ".../Prune CI Registry/script"
```

Keeps 14 days of `ci-*` fingerprint markers and **15** days of `engram-ci`
images, prunes the rest, then garbage-collects.

**The marker window MUST be shorter than the image window.** A marker means
"this content already went green", and CI skips `prebuild-ci-image` on that
basis — so a marker that outlives its image makes CI skip the build and then
fail pulling an image nobody rebuilt. That is not hypothetical: after the first
prune, a re-run failed with `prebuild-ci-image  skipped` and e2e dying on
`manifest unknown`, because the marker was still asserting a proof for an image
that had been deleted. Markers are written *after* their image, so an equal
window would let them outlive it — hence images get `KEEP_DAYS + 1`.

Deleting a marker is safe in the other direction: CI reads its absence as
"not cached" and simply re-runs the job. Marker repos fail open, image repos
fail closed. When in doubt, expire the marker.

First run: **829 tags -> 258, blobs 61G -> 27G** (63G before an initial
`--delete-untagged`). Knobs: `KEEP_DAYS`, `MIN_IDLE_SEC`, `DRY_RUN=1`.

### The race is real — I caused an outage proving it

Do not relax `MIN_IDLE_SEC`.

I checked "no CI runs in flight" via the GitHub API, saw `prebuild-ci-image` had
already reported **completed**, and ran GC. It swept a manifest whose tag had
been written **21 seconds earlier**, and the dependent jobs died three seconds
later with:

```
Error response from daemon: manifest for 10.0.20.214:5001/engram-ci:<tag> not found: manifest unknown
```

Job status is a control-plane fact; the hazard is in the data plane. A push
reports complete when the HTTP call returns, which is not when the tag link is
durable and visible to GC's mark phase. The script therefore gates on the thing
GC actually races — **the mtime of the newest tag on disk** — and refuses to run
within `MIN_IDLE_SEC` (default 1800s) of any push.

Two follow-on lessons:

- **A `--failed` rerun does not repair this.** `prebuild-ci-image` already
  succeeded, so it is not re-run, and the dependent jobs keep pulling the tag
  that no longer exists. Use a **full** `gh run rerun <id>` so the image is
  rebuilt and re-pushed.
- **A swept manifest leaves a dangling tag** that serves 404s forever and makes
  "is it already in the registry?" checks lie. The script now sweeps those at
  the end so the next prebuild rebuilds instead.

### Residual risk the guard does NOT cover

`MIN_IDLE_SEC` gates the *start* of the window, but the sweep itself runs for
minutes (6m20s on the first 61G run). A push landing mid-sweep hits the same
race, and nothing can retroactively save it. The script re-checks the newest tag
afterwards and logs a loud `WARNING` if one appeared, so a red build in that
window is attributable rather than a mystery. The real fix, if this ever bites
again, is putting the registry in read-only mode for the duration
(`REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED=true`) — which costs a restart,
so it was not worth it for a Sunday-05:00 job.

Also in the script, both learned the hard way in review:

- It holds a `flock`. Two concurrent sweeps would each mark against a tag set the
  other is deleting, so blobs still referenced by the loser get swept.
- The `garbage-collect` exit status is checked. The first version piped it to
  `grep -c ... || true`, which reported "blobs deleted: 0" and exited clean
  whether GC had swept nothing or crashed — and by then the tag references were
  already gone, so a silent failure would leave orphaned blobs forever with
  nothing in the log to say so.

## Related

- `runner-vm-setup.md` — the runners that push to this registry
- `ci-pipeline-gating.md` — which jobs gate, and what a `skipping` really means
- `fastraid-deploy.md` — the rest of the FastRaid host layout
