# ci/fingerprint/record.sh
. "$(dirname "${BASH_SOURCE[0]}")/compute.sh"
record_marker() {
  [ "${IS_FULL_RUN:-false}" = true ] || { echo "not a full run; skip marker for $1"; return 0; }
  [ -n "${LOCAL_REGISTRY:-}" ] || { echo "::warning::LOCAL_REGISTRY unset; marker $1 not recorded"; return 0; }
  # Prefer the hash the fingerprint job already emitted + looked up (MARKER_HASH)
  # so the recorded tag matches a later run's lookup EXACTLY — recomputing here
  # would depend on BEAM being on the recording runner's host (it isn't, for the
  # docker-bound e2e/storage jobs), silently producing a mismatched tag.
  local job="$1" h; h="${MARKER_HASH:-$(job_hash "$job")}"
  local d; d=$(mktemp -d)
  if ( cd "$d" && echo FROM scratch > Dockerfile && echo "$h" > marker \
        && docker build -q -t "${LOCAL_REGISTRY}/ci-$job:$h" -f Dockerfile . >/dev/null \
        && docker push -q "${LOCAL_REGISTRY}/ci-$job:$h" >/dev/null ); then
    rm -rf "$d"; echo "recorded ci-$job:$h"
  else
    # Non-fatal: a registry blip must not fail an otherwise-green full run, but
    # surface it (the old code echoed "recorded" even when the push failed).
    rm -rf "$d"; echo "::warning::marker push failed for ci-$job:$h"; return 0
  fi
}
if [ "${1:-}" = record ]; then record_marker "${2:?job}"; fi
