# CI registry (`:5001`) down, and how to keep and prune it safely

_Last verified: 2026-10-18_

The FastRaid CI registry (`LocalCIRegistry`, `10.0.20.214:5001`) holds the
`engram-ci` images and the `ci-*` fingerprint markers. Until 2026-08 the Unraid
Appdata Backup plugin stopped it every Monday ~04:00 to tar it, breaking CI for
~50 minutes. That is fixed (`dontStop` + `skipBackup`, below). The traps here
recur for any container the backup touches and for any registry pruning.

## Symptom

The image builds and only the push fails:

```
The push refers to repository [10.0.20.214:5001/engram-ci]
Get "http://10.0.20.214:5001/v2/": dial tcp 10.0.20.214:5001: connect: connection refused
```

Every e2e job (`e2e-browser`, `e2e-crdt`, `e2e-clerk`, `headless-protocol`)
then reports **skipping** because it depends on that image. The code is fine.

## Recognise a deliberate stop vs a real fault

```bash
ssh root@10.0.20.214 'docker inspect LocalCIRegistry \
  --format "policy={{.HostConfig.RestartPolicy.Name}} exit={{.State.ExitCode}} oom={{.State.OOMKilled}} restarts={{.RestartCount}}"'
# policy=unless-stopped exit=2 oom=false restarts=0
ssh root@10.0.20.214 'ps aux | grep -iE "appdata|backup|tar " | grep -v grep'
```

`restarts=0` under `unless-stopped` means something ran `docker stop` on it. A
crash loop shows a non-zero `RestartCount`; a real fault usually shows
`oom=true` or a full volume. A live `tar ... LocalCIRegistry.tar.gz` confirms
the backup.

**Do not `docker start` it mid-backup.** That corrupts the archive (the
registry writes into the directory tar is reading) and fights the plugin, which
restarts it when the tar finishes. Wait, then re-run:

```bash
until ssh root@10.0.20.214 'docker ps --filter name=LocalCIRegistry --filter status=running -q' | grep -q .; do sleep 60; done
gh run rerun <run-id> --failed
```

## Appdata Backup: use `skipBackup`, not `skip`

Config: `/boot/config/plugins/appdata.backup/config.json`. Current entry:

```json
"LocalCIRegistry": {
    "skipBackup": "yes",          // the one that actually gates the tar
    "dontStop": "yes",            // load-bearing: this is what broke CI
    "skip": "yes",                // harmless, but do NOT rely on it
    "ignoreBackupErrors": "no",
    "group": "", "backupExtVolumes": "no", "updateContainer": "",
    "exclude": "", "verifyBackup": ""
}
```

**`skip` is only honoured for containers listed in `containerOrder`.**
`ABHelper.php::sortContainers()` reads `skip` only while walking
`containerOrder`, then `array_merge`s every unlisted container back in unchecked.
`containerOrder` is rewritten only when the settings page is saved, so a
container created after the last save gets backed up despite `skip: yes`.
`skipBackup` is checked in `backupContainer()` for every container regardless of
order. Rule: set `skipBackup`; trust `skip` only for a container known to be in
`containerOrder`.

`ignoreBackupErrors: yes` mutes the alert and changes nothing else. Do not use
it as a fix.

To keep one path out of a container's backup (e.g. a rebuildable bucket next to
real data), use `"exclude": "<abs path>"`, which becomes `tar --exclude`.

### Failed backup dirs are never pruned

A failed run skips retention entirely (`RETENTION WILL NOT BE CHECKED!`), and
the retention pass cannot parse `-failed`-suffixed dir names
(`date_create_from_format("??_Ymd_His", "ab_20260817_030002-failed")` is
`false`), so it keeps them forever. After any stretch of red backups, delete
`-failed` dirs by hand on both FastRaid and SlowRaid.

## Host layout

- `LocalCIRegistry`: plain `registry:2`, `10.0.20.214:5001 -> 5000`.
- Data: `/mnt/cache/appdata/local-ci-registry`.
- DockerMan template:
  `/boot/config/plugins/dockerMan/templates-user/my-LocalCIRegistry.xml`.
  Change env there, then recreate with the dockerman label, or the next
  DockerMan update reverts it.
- Repos: `engram-ci` (one app image per CI run), `engram-deps` (below), and the
  `ci-*` fingerprint markers.
- `REGISTRY_STORAGE_DELETE_ENABLED=true` since 2026-10-18 (template + container),
  so `DELETE /v2/<repo>/manifests/<digest>` returns `202`. Before that the API
  refused deletes; the prune script never needed it (it works on disk).

### `engram-deps`

Prebuilt toolchain + compiled-deps base image (PR #2014). Tag = sha256 of
`Dockerfile`, `mix.lock`, `config/config.exs`, `config/prod.exs`,
`native/Cargo.lock`. Rebuilt only when one of those changes (~9 min cold);
otherwise reused, which took the CI image build from 7m to 1m44s. Retention
must never delete the newest tag, or every run pays the cold build.

## Pruning the registry: retention, not GC

One full app image is pushed per CI run and nothing else prunes them. A plain
`registry garbage-collect` reclaims almost nothing, because GC only removes
blobs no manifest references and every manifest is still tagged. The lever is
**tag retention**: remove tag dirs under `repositories/<repo>/_manifests/tags/`,
then `garbage-collect --delete-untagged`. `storage.delete.enabled` gates only the
HTTP DELETE API, not the CLI (on-disk tag removal works either way).

Source of truth: **`ci/prune-ci-registry.sh`**, copied to the FastRaid host as
the User Script "Prune CI Registry"
(`/boot/config/plugins/user.scripts/scripts/Prune CI Registry/script`). Knobs:
`KEEP_DAYS` (default 14), `MIN_IDLE_SEC` (default 1800), `DRY_RUN=1`. It deletes
tag dirs on disk (`engram-ci` > 15d, `ci-*` markers > 14d, `engram-deps` > 15d
except the newest), then runs `garbage-collect --delete-untagged`.

**Drift:** as of 2026-10-18 the `engram-deps` rule exists only in the host copy;
the repo script still prunes `engram-ci` + markers only. Port it before the next
copy-to-host, or the copy silently drops it. Host edits leave backups with the
suffix `bak-2026-10-18`.

### The schedule lives in `customSchedule.cron`

The User Scripts plugin builds `/etc/cron.d/root` (via `update_cron`) from
`/boot/config/plugins/user.scripts/customSchedule.cron`. Editing
`schedule.json` alone changes nothing. Runs are now **daily 03:30** (was weekly
Sun 05:00). The weekly run hit the idle guard on 2026-10-11 and aborted, so a
whole extra week piled up: 473 `engram-ci` tags (146 past 14 days), 1001 stale
markers, 54 GB. Daily gives it seven chances a week at a quiet window. If the
registry is growing, read the log first:
`/tmp/user.scripts/tmpScripts/Prune CI Registry/log.txt` (an `ABORT` on the idle
guard is expected occasionally, not every day).

**The marker window MUST be shorter than the image window.** A marker says
"this content already went green", so CI skips `prebuild-ci-image`. A marker
that outlives its image makes CI skip the build, then fail pulling with
`manifest unknown`. Markers are written after their image, so images get
`KEEP_DAYS + 1`. Expiring a marker is always safe: CI reads its absence as "not
cached" and re-runs. Marker repos fail open, image repos fail closed.

**Never GC near a push.** A push reports complete before its tag link is
durable to GC's mark phase. Checking "no CI in flight" via the GitHub API is not
enough: a GC once swept a manifest tagged 21 seconds earlier. The script gates
on the newest tag's on-disk mtime and refuses to run within `MIN_IDLE_SEC`. Do
not relax it.

- **A `--failed` rerun does not repair a swept image.** `prebuild-ci-image`
  already succeeded, so it is not re-run and consumers keep pulling the missing
  tag. Use a full `gh run rerun <id>`.
- **A swept manifest leaves a dangling tag** that 404s forever and makes
  "already in the registry?" checks lie. The script sweeps these at the end.
- **Residual risk:** a push landing mid-sweep still races (the sweep takes
  minutes). The script re-checks the newest tag afterwards and logs a
  `WARNING`. The real fix, if it bites, is read-only mode for the sweep
  (`REGISTRY_STORAGE_MAINTENANCE_READONLY_ENABLED=true`), which costs a restart.
- The script holds a `flock` (two concurrent sweeps delete blobs the other still
  references) and checks the `garbage-collect` exit status (never pipe it
  through `grep || true`).

## Runner-side image prune

The registry is not the only place images pile up. `cron.yml`'s nightly runner
prune keeps only the newest `*/engram-ci:*` and `*/engram-deps:*` on each runner.
The old `reference=engram-ci:*` filter never matched, because pulled tags are
registry-qualified (`10.0.20.214:5001/engram-ci:...`); match on `*/<repo>:*`.

## Related

- `../engram-workspace/docs/context/runner-vm-setup.md`: the runners that push here
- [ci-fingerprint-markers.md](ci-fingerprint-markers.md): what a marker means
- [ci-pipeline-gating.md](ci-pipeline-gating.md): what a `skipping` job means
- `../engram-workspace/docs/context/fastraid-deploy.md`: FastRaid host layout
