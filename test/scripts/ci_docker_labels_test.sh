#!/usr/bin/env bash
# test/scripts/ci_docker_labels_test.sh
#
# Guards ci/bin/ci-docker, the one place CI containers get their
# runner-ownership labels (engram-ci.runner / engram-ci.run). The runner
# host's reaper removes a killed job's containers at once by those labels;
# an unlabelled container lingers ~100 min holding memory, which OOM-killed
# the next job on minipc (engram-infra#1758).
#
#  1. No CI path may create a container, network or volume with plain
#     `docker`; it must go through ci/bin/ci-docker.
#  2. Every image-bearing service in ci/compose*.yml carries *ci-labels.
#  3. ci-docker adds the labels on a runner, adds nothing off one, and
#     passes every other command and argument through untouched.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
WRAPPER="$ROOT/ci/bin/ci-docker"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. no bypass in CI paths ---
# Command position only: start of line or after `if`/`then`/`do`/`exec`/
# `$(`/`;`/`&&`/`||`/`|`, so `echo "docker run failed"` and comments pass.
cd "$ROOT"
bypass=$(git grep -nE \
  '(^|[;&|(]|\bif|\bthen|\bdo|\bexec|\$\()[[:space:]]*docker[[:space:]]+(run|create|container[[:space:]]+(run|create)|network[[:space:]]+create|volume[[:space:]]+create)\b' \
  -- .github ci e2e scripts Makefile ':!ci/bin/ci-docker' ':!*.md' \
  | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
# Programmatic spawns, e.g. execFileSync("docker", ["run", ...]).
bypass+=$(git grep -nE "[\"']docker[\"'],[[:space:]]*\[?[[:space:]]*[\"'](run|create)[\"']" \
  -- e2e scripts ':!*.md' || true)
[ -z "$bypass" ] || fail "plain docker run/create in CI paths; use ci/bin/ci-docker:
$bypass"

# --- 2. compose services carry the labels ---
for f in ci/compose*.yml; do
  missing=$(awk '
    /^services:/ { in_s = 1; next }
    /^[^ #]/     { in_s = 0 }
    in_s && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
      if (svc != "" && img && !lab) print svc
      svc = $1; img = 0; lab = 0; next
    }
    in_s && /^    image:/              { img = 1 }
    in_s && /^    labels: \*ci-labels/ { lab = 1 }
    END { if (svc != "" && img && !lab) print svc }
  ' "$f")
  [ -z "$missing" ] || fail "$f: service(s) without labels: *ci-labels: $missing"
done

# --- 3. wrapper behaviour, against a fake docker that records its argv ---
mkdir "$TMP/bin"
cat > "$TMP/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$ARGV_OUT"
SH
chmod +x "$TMP/bin/docker"
export ARGV_OUT="$TMP/argv"
run() { PATH="$TMP/bin:$PATH" "$WRAPPER" "$@"; cat "$ARGV_OUT"; }

on_runner() { RUNNER_NAME=minipc-1 GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=2 run "$@"; }
off_runner() { env -u RUNNER_NAME GITHUB_RUN_ID=42 PATH="$TMP/bin:$PATH" "$WRAPPER" "$@"; cat "$ARGV_OUT"; }

expected_run=$'run\n--label\nengram-ci.runner=minipc-1\n--label\nengram-ci.run=42\n--label\nengram-ci.run-attempt=2\n-d\n--name\na b\nimg'
[ "$(on_runner run -d --name 'a b' img)" = "$expected_run" ] || fail "run: labels missing or args mangled: $(cat "$ARGV_OUT")"

[ "$(on_runner create img | head -3)" = $'create\n--label\nengram-ci.runner=minipc-1' ] || fail "create: no labels"

[ "$(on_runner network create net1)" = $'network\ncreate\n--label\nengram-ci.runner=minipc-1\n--label\nengram-ci.run=42\n--label\nengram-ci.run-attempt=2\nnet1' ] \
  || fail "network create: no labels: $(cat "$ARGV_OUT")"

[ "$(on_runner volume create v1 | head -4)" = $'volume\ncreate\n--label\nengram-ci.runner=minipc-1' ] || fail "volume create: no labels"

[ "$(off_runner run -d img)" = $'run\n-d\nimg' ] || fail "off a runner, run must get no labels: $(cat "$ARGV_OUT")"

[ "$(on_runner ps -aq --filter 'label=x y')" = $'ps\n-aq\n--filter\nlabel=x y' ] || fail "ps must pass through untouched"

[ "$(on_runner network rm net1)" = $'network\nrm\nnet1' ] || fail "network rm must pass through untouched"

[ "$(on_runner show-labels c1 | sed -n 1,3p)" = $'inspect\n-f\n{{.Name}} engram-ci.runner={{index .Config.Labels "engram-ci.runner"}} engram-ci.run={{index .Config.Labels "engram-ci.run"}}' ] \
  || fail "show-labels: wrong inspect: $(cat "$ARGV_OUT")"

echo "OK: ci-docker labels (no bypass, compose labelled, wrapper behaviour)"
