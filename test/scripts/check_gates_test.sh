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

# The SKIP_INTENDED expressions in verify.yml's `ci` job must mirror each
# gate's own `if:`, and every gate in `ci.needs` must be passed to
# check-gates. Nothing else enforces that, and two drifts fail OPEN:
#   - a job added to `ci.needs` but not to the check-gates call is ignored;
#   - SKIP_INTENDED reading `needs.<X>.result == 'skipped'` is only sound while
#     X needs nothing but fingerprint (which `ci` checks first). If X gains an
#     upstream, X's failure-skip would count as intended.
check_mirror() { # check_mirror <verify.yml>
  python3 - "$1" <<'PY'
import re, sys, yaml
jobs = yaml.safe_load(open(sys.argv[1]))["jobs"]
ci = jobs["ci"]
run = next(s["run"] for s in ci["steps"] if s.get("name") == "Check required jobs")
args = dict(re.findall(r'"([\w-]+):\$\{\{ needs\.[\w-]+\.result \}\}:\$\{\{ (.*?) \}\}"', run))
tok = re.compile(r"needs\.fingerprint\.outputs\.[\w-]+|github\.(?:event_name|ref|actor)")
as_list = lambda v: [v] if isinstance(v, str) else (v or [])
errs = []
gates = set(as_list(ci["needs"])) - {"fingerprint", "version-check", "prebuild-ci-image"}
if gates != set(args):
    errs.append(f"ci.needs gates {sorted(gates)} != check-gates args {sorted(args)}")
for name, expr in args.items():
    job = jobs.get(name) or {}
    want, got = set(tok.findall(str(job.get("if", "")))), set(tok.findall(expr))
    if want != got:
        errs.append(f"{name}: if: reads {sorted(want)}, SKIP_INTENDED reads {sorted(got)}")
    for up in re.findall(r"needs\.([\w-]+)\.result", expr):
        if up not in as_list(job.get("needs")) or as_list(jobs[up].get("needs")) != ["fingerprint"]:
            errs.append(f"{name}: SKIP_INTENDED trusts {up}'s skip, but {up} is not a direct need whose only need is fingerprint")
print("\n".join(errs))
sys.exit(1 if errs else 0)
PY
}
WF="$ROOT/.github/workflows/verify.yml"
check_mirror "$WF" || fail "verify.yml SKIP_INTENDED drifted from the gates' if:"
echo "ok: SKIP_INTENDED mirrors every gate's if:"

TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mutant() { # mutant <label> <python replace-expr on s>
  python3 -c "import sys; s=open(sys.argv[1]).read(); n=$2; assert n!=s, 'mutation did not apply'; open(sys.argv[2],'w').write(n)" "$WF" "$TMP/m.yml"
  ! check_mirror "$TMP/m.yml" >/dev/null || fail "mirror check missed: $1"
  echo "ok: mirror check catches $1"
}
mutant "prebuild-ci-image gaining an upstream" \
  "s.replace('  prebuild-ci-image:\n    needs: fingerprint\n', '  prebuild-ci-image:\n    needs: [fingerprint, prebuild-mix]\n', 1)"
mutant "a needed gate missing from the check-gates call" \
  "'\n'.join(l for l in s.split('\n') if not l.lstrip().startswith('\"static-checks:\${{'))"
mutant "a skip dropped from a gate's if:" \
  "s.replace(\"if: github.event_name != 'repository_dispatch' && needs.fingerprint.outputs.skip-lint != 'true'\", \"if: github.event_name != 'repository_dispatch'\", 1)"

echo "check-gates: all tests passed"
