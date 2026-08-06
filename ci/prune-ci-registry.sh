#!/bin/bash
# Retention for the local CI registry (LocalCIRegistry, 10.0.20.214:5001).
#
# THIS FILE IS THE SOURCE OF TRUTH. It runs on the FastRaid Unraid host, not in
# CI, installed as a User Script and fired by cron:
#
#   dest: /boot/config/plugins/user.scripts/scripts/Prune CI Registry/script
#   cron: 0 5 * * 0   (Sundays 05:00, via /etc/cron.d/root)
#
# To change it: edit here, merge, then copy it up —
#   scp ci/prune-ci-registry.sh \
#       "root@10.0.20.214:/boot/config/plugins/user.scripts/scripts/Prune CI Registry/script"
#
# Lives beside ci/fingerprint/ deliberately: that is what WRITES the ci-* pass
# markers this script expires, and the two retention windows have to stay in
# step (see the marker/image note below).
#
# CI pushes one full app image per run and nothing ever prunes them: 829 tags /
# 63G as of 2026-08-03, growing ~1-2G per run. See engram-app/Engram#1224 and
# docs/context/ci-registry-down-during-appdata-backup.md.
#
# Two-step, because a plain garbage-collect reclaims nothing on its own: GC is
# mark-and-sweep over MANIFEST REFERENCES, and a tag is a reference. So we drop
# old tag references first, then let GC sweep the now-unreferenced manifests.
#
# The ci-* fingerprint pass-marker repos MUST be pruned alongside the images,
# and slightly sooner. A marker means "this content already went green", and CI
# skips prebuild-ci-image on that basis — so a marker that outlives its image
# makes CI skip the build and then fail pulling an image nobody rebuilt. That
# is not hypothetical: it is exactly how a rerun failed on 2026-08-03 after the
# first prune, with prebuild-ci-image `skipped` and e2e dying on `manifest
# unknown`. Markers are written AFTER their image, so an equal window would let
# them outlive it; images therefore get KEEP_DAYS + 1.
#
# RACE — this bit me for real on 2026-08-03, do not weaken the guard below.
# A blob uploaded WHILE gc runs can be swept before its manifest is durable. I
# checked "no CI runs in flight" and ran anyway; prebuild-ci-image had already
# reported `completed`, yet a tag written 21s earlier had its manifest swept and
# the dependent e2e jobs died with "manifest unknown". Job status is NOT a
# sufficient interlock. The only cheap reliable signal is the age of the newest
# tag on disk, so that is what MIN_IDLE_SEC gates on.
set -euo pipefail

KEEP_DAYS="${KEEP_DAYS:-14}"
MIN_IDLE_SEC="${MIN_IDLE_SEC:-1800}"   # refuse to GC within 30min of any push
DRY_RUN="${DRY_RUN:-0}"
CONTAINER=LocalCIRegistry
ROOT=/mnt/cache/appdata/local-ci-registry/docker/registry/v2
REPOS="$ROOT/repositories"
TAGS="$REPOS/engram-ci/_manifests/tags"

log() { echo "[$(date '+%F %T')] $*"; }

# One at a time. Two concurrent sweeps would each mark against a tag set the
# other is deleting, so blobs still referenced by the loser get swept.
exec 9>/var/lock/prune-ci-registry.lock
flock -n 9 || { log "another prune is already running"; exit 0; }

# Refuse rather than guess if the layout is not what we expect — a bad path
# with `rm -rf` behind it is the one unrecoverable mistake available here.
[ -d "$TAGS" ] || { log "FATAL: tag dir missing: $TAGS"; exit 1; }
docker ps --filter "name=$CONTAINER" --filter status=running -q | grep -q . \
  || { log "FATAL: $CONTAINER not running"; exit 1; }

# Refuse if anything was pushed recently — see the RACE note above.
newest_epoch=$(find "$TAGS" -maxdepth 1 -mindepth 1 -type d -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1)
idle=$(( $(date +%s) - ${newest_epoch:-0} ))
if [ "$idle" -lt "$MIN_IDLE_SEC" ]; then
  log "ABORT: newest tag is ${idle}s old (< ${MIN_IDLE_SEC}s) — a push may still be settling"
  exit 1
fi
log "quiet for ${idle}s (>= ${MIN_IDLE_SEC}s)"

IMAGE_KEEP_DAYS=$((KEEP_DAYS + 1))
total=$(find "$TAGS" -maxdepth 1 -mindepth 1 -type d | wc -l)
stale=$(find "$TAGS" -maxdepth 1 -mindepth 1 -type d -mtime "+$IMAGE_KEEP_DAYS" | wc -l)
before=$(du -sh "$ROOT/blobs" | cut -f1)
markers_stale=$(find "$REPOS"/ci-*/_manifests/tags -maxdepth 1 -mindepth 1 -type d -mtime "+$KEEP_DAYS" 2>/dev/null | wc -l)
log "tags=$total stale(>${IMAGE_KEEP_DAYS}d)=$stale keep=$((total - stale)) markers_stale(>${KEEP_DAYS}d)=$markers_stale blobs=$before"

if [ "$stale" -eq 0 ] && [ "$markers_stale" -eq 0 ]; then
  log "nothing to prune"
  exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
  log "DRY_RUN=1 — would delete $stale image tags + $markers_stale markers, then garbage-collect"
  exit 0
fi

find "$TAGS" -maxdepth 1 -mindepth 1 -type d -mtime "+$IMAGE_KEEP_DAYS" -exec rm -rf {} +
# Markers first-expiring, per the note above.
find "$REPOS"/ci-*/_manifests/tags -maxdepth 1 -mindepth 1 -type d -mtime "+$KEEP_DAYS" -exec rm -rf {} + 2>/dev/null || true
log "pruned $stale image tags + $markers_stale markers; running garbage-collect"

# Capture the exit status. The previous `| grep -c ... || true` reported
# "blobs deleted: 0" and exited clean whether GC had swept nothing or crashed
# outright — the tag references were already gone by then, so a silent failure
# left the registry holding unreferenced blobs forever with nothing to say so.
gc_log=$(mktemp)
if docker exec "$CONTAINER" \
     registry garbage-collect --delete-untagged /etc/docker/registry/config.yml \
     >"$gc_log" 2>&1; then
  log "blobs deleted: $(grep -cE '^blob eligible for deletion' "$gc_log" || true)"
else
  log "FATAL: garbage-collect failed (tags are already pruned; blobs remain)"
  tail -20 "$gc_log" | sed 's/^/    /'
  rm -f "$gc_log"
  exit 1
fi
rm -f "$gc_log"

# Self-heal, across EVERY repo rather than just engram-ci: a tag whose manifest
# blob is gone serves 404s forever and makes "is it already in the registry?"
# checks lie. On engram-ci that fails closed (a pull errors); on the ci-* marker
# repos it fails open (CI reads 404 as "not cached" and re-runs the job, which
# is safe) — but both are litter, and both showed up in practice.
dangling=0
for d in "$REPOS"/*/_manifests/tags/*/; do
  link="$d/current/link"; [ -f "$link" ] || continue
  h=$(sed 's/sha256://' "$link")
  [ -d "$ROOT/blobs/sha256/${h:0:2}/$h" ] || { rm -rf "$d"; dangling=$((dangling + 1)); }
done
[ "$dangling" -gt 0 ] && log "removed $dangling dangling tag(s)"

# The idle guard covers the START of the window, but GC itself runs for minutes
# and a push landing mid-sweep hits the same race. Nothing can retroactively
# save it, so say so loudly instead of leaving a mystery red build.
now_newest=$(find "$TAGS" -maxdepth 1 -mindepth 1 -type d -printf '%T@\n' | sort -n | tail -1 | cut -d. -f1)
if [ "${now_newest:-0}" -gt "${newest_epoch:-0}" ]; then
  log "WARNING: a tag was pushed DURING the sweep — if a CI run just failed with"
  log "WARNING: 'manifest unknown', that is why. Full \`gh run rerun <id>\` fixes it."
fi

after=$(du -sh "$ROOT/blobs" | cut -f1)
log "done: blobs $before -> $after, tags $(find "$TAGS" -maxdepth 1 -mindepth 1 -type d | wc -l)"
