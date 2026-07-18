# ci/fingerprint/compute.sh
. "$(dirname "${BASH_SOURCE[0]}")/groups.sh"
# job -> groups (SUPERSETS; see spec). plugin handled via PLUGIN_SHA.
job_names() { echo "lint unit-tests storage-database e2e-clerk e2e-crdt e2e-browser n1-compat build-and-publish-image"; }
job_groups() {
  # ci-meta on EVERY job so a workflow/fingerprint-script change re-runs all jobs.
  # e2e jobs include `priv` because the e2e stack boots the real release, which
  # runs Engram.Release.migrate() at startup — a migration-only change must bust them.
  case "$1" in
    lint)              echo "elixir-src unit-tests lint-config ci-meta" ;;
    unit-tests)        echo "elixir-src unit-tests priv ci-meta" ;;
    storage-database)  echo "elixir-src priv docker-image ci-meta" ;;
    # e2e-crdt also runs tests/api_only/ (absorbed the old e2e-local job).
    # Neither suite exercises the SPA, so `frontend` is deliberately absent:
    # a React-only change can't alter REST responses served from lib/.
    e2e-clerk|e2e-crdt) echo "docker-image elixir-src e2e-harness priv +plugin ci-meta" ;;
    e2e-browser)       echo "docker-image elixir-src e2e-harness frontend priv ci-meta" ;;
    n1-compat)         echo "elixir-src priv ci-meta" ;;
    build-and-publish-image) echo "docker-image elixir-src frontend priv ci-meta" ;;
    *) echo "unknown job: $1" >&2; return 2 ;;
  esac
}
job_hash() {
  local job="$1" acc="" g
  for g in $(job_groups "$job"); do
    if [ "$g" = "+plugin" ]; then acc="$acc plugin:${PLUGIN_SHA:-}"; else acc="$acc $(group_hash "$g" "$BEAM_TAG")"; fi
  done
  printf '%s' "$acc" | sha256sum | cut -d' ' -f1
}
marker_exists() { # ci-<job>:<hash>
  [ -n "${LOCAL_REGISTRY:-}" ] || return 1
  local body; body=$(curl -s --max-time 5 -H "Accept: application/vnd.docker.distribution.manifest.v2+json" \
    "http://${LOCAL_REGISTRY}/v2/ci-$1/manifests/$2" || true)
  printf '%s' "$body" | jq -e 'type=="object" and has("schemaVersion")' >/dev/null 2>&1
}
emit_skips() { # writes skip-<job>/hash-<job> to GITHUB_OUTPUT
  local job h skip
  for job in $(job_names); do
    h=$(job_hash "$job")
    # Full runs (main / [ci-full] / force_full) NEVER skip: main is the safety
    # net that re-runs everything and re-seeds markers, so force skip=false there
    # regardless of marker presence. PRs skip only when a marker already exists.
    if [ "${IS_FULL_RUN:-false}" = true ]; then
      skip=false
    elif marker_exists "$job" "$h"; then
      skip=true
    else
      skip=false
    fi
    echo "skip-$job=$skip" >> "$GITHUB_OUTPUT"
    echo "hash-$job=$h"    >> "$GITHUB_OUTPUT"
  done
}
# `if` (not `&& ... || true`) so a real emit failure propagates while sourcing
# this file with no args stays exit-0 (source-safe for compute_test / record.sh).
if [ "${1:-}" = emit ]; then emit_skips; fi
