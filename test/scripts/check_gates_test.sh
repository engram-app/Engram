#!/usr/bin/env bash
# test/scripts/check_gates_test.sh
#
# Guards ci/bin/check-gates, the verdict of verify.yml's aggregate `ci` job.
# The old inline loop passed any `skipped` gate, so a prebuild-mix failure
# that skipped unit-tests / lint / migration-gates still turned `ci` green
# with zero tests run (#2453). A skip must pass only when the job's own
# fingerprint/event filter asked for it.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CHECK="${CHECK_GATES:-$ROOT/ci/bin/check-gates}"
export GITHUB_STEP_SUMMARY=/dev/null

fail() { echo "FAIL: $*" >&2; exit 1; }
expect() { # expect <exit-code> <label> <gate args...>
  local want="$1" label="$2"; shift 2
  local got=0
  "$CHECK" "$@" >/dev/null 2>&1 || got=$?
  [ "$got" = "$want" ] || fail "$label: exit $got, want $want"
  echo "ok: $label"
}

expect 0 "all success" \
  unit-tests:success:false lint:success:false migration-gates:success:false

# Run 42023674269: prebuild-mix failed, its dependents skipped, nothing
# told them to skip.
expect 1 "prebuild failure skips downstream" \
  unit-tests:skipped:false lint:skipped:false migration-gates:skipped:false frontend-lint:success:false

expect 1 "one upstream-failure skip among successes" \
  unit-tests:success:false storage-database:skipped:false

expect 0 "fingerprint skip (marker hit)" \
  unit-tests:skipped:true lint:skipped:true frontend-lint:success:false

expect 0 "event filter skip (migration-gates on main)" \
  unit-tests:success:false migration-gates:skipped:true

expect 1 "cancelled" unit-tests:cancelled:false lint:success:false
expect 1 "cancelled even if a skip was intended" unit-tests:cancelled:true
expect 1 "failure" unit-tests:failure:false
expect 1 "missing result" unit-tests::false

# The summary names exactly the inherited gates.
out=$(GITHUB_STEP_SUMMARY=/dev/stdout "$CHECK" unit-tests:skipped:true lint:success:false)
grep -qF -- '- `unit-tests`' <<<"$out" || fail "summary lists unit-tests"
! grep -qF -- '- `lint`' <<<"$out" || fail "summary must not list lint"
echo "ok: summary lists inherited gates only"

echo "check-gates: all tests passed"
