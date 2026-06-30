# ci/fingerprint/compute.sh
. "$(dirname "${BASH_SOURCE[0]}")/groups.sh"
# job -> groups (SUPERSETS; see spec). plugin handled via PLUGIN_SHA.
job_names() { echo "lint unit-tests storage-database e2e-clerk e2e-crdt e2e-local e2e-browser n1-compat build-and-publish-image"; }
job_groups() {
  case "$1" in
    lint)              echo "elixir-src unit-tests lint-config" ;;
    unit-tests)        echo "elixir-src unit-tests migrations" ;;
    storage-database)  echo "elixir-src migrations docker-image" ;;
    e2e-clerk|e2e-crdt) echo "docker-image elixir-src e2e-harness +plugin" ;;
    e2e-local|e2e-browser) echo "docker-image elixir-src e2e-harness frontend" ;;
    n1-compat)         echo "elixir-src migrations" ;;
    build-and-publish-image) echo "docker-image elixir-src frontend migrations" ;;
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
    if marker_exists "$job" "$h"; then skip=true; else skip=false; fi
    echo "skip-$job=$skip" >> "$GITHUB_OUTPUT"
    echo "hash-$job=$h"    >> "$GITHUB_OUTPUT"
  done
}
[ "${1:-}" = emit ] && emit_skips || true
