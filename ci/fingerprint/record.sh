# ci/fingerprint/record.sh
. "$(dirname "${BASH_SOURCE[0]}")/compute.sh"
record_marker() {
  [ "${IS_FULL_RUN:-false}" = true ] || { echo "not a full run; skip marker for $1"; return 0; }
  [ -n "${LOCAL_REGISTRY:-}" ] || { echo "::warning::LOCAL_REGISTRY unset; marker $1 not recorded"; return 0; }
  local job="$1" h; h=$(job_hash "$job")
  local d; d=$(mktemp -d); ( cd "$d" && echo FROM scratch > Dockerfile && echo "$h" > marker \
    && docker build -q -t "${LOCAL_REGISTRY}/ci-$job:$h" -f Dockerfile . >/dev/null \
    && docker push -q "${LOCAL_REGISTRY}/ci-$job:$h" >/dev/null )
  rm -rf "$d"; echo "recorded ci-$job:$h"
}
[ "${1:-}" = record ] && record_marker "${2:?job}" || true
