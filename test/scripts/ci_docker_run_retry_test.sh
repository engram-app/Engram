#!/usr/bin/env bash
# test/scripts/ci_docker_run_retry_test.sh
#
# Guards ci/bin/ci-docker-run-retry with a stub `docker` on PATH:
#  1. bind error twice, then success: succeeds on attempt 3, cleans up by name
#     before each retry.
#  2. non-port error (image pull): fails at once, no retry, no cleanup.
#  3. bind error every time: bounded, fails loud.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

mkdir "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
if [ "$1" = "rm" ]; then exit 0; fi
n=$(grep -c '^run ' "$STUB_LOG")
if [ "$STUB_MODE" = pull ]; then echo "Error: pull access denied for nope" >&2; exit 125; fi
if [ "$n" -le "${STUB_FAILS:-0}" ]; then
  echo "docker: Error response from daemon: RootlessKit PortManager.AddPort(): listen tcp4 127.0.0.1:32774: bind: address already in use" >&2
  exit 125
fi
echo cid123
EOF
chmod +x "$TMP/bin/docker"

run() { # mode fails
  : > "$TMP/log"
  STUB_MODE="$1" STUB_FAILS="$2" STUB_LOG="$TMP/log" PATH="$TMP/bin:$PATH" \
    DOCKER_RUN_RETRY_SLEEP=0 "$ROOT/ci/bin/ci-docker-run-retry" -d --name c1 -p 127.0.0.1:0:6333 img
}
runs() { grep -c '^run ' "$TMP/log" || true; }
rms() { grep -c '^rm -f c1' "$TMP/log" || true; }

run port 2 >/dev/null 2>&1 || fail "should succeed after 2 bind failures"
[ "$(runs)" = 3 ] && [ "$(rms)" = 2 ] || fail "case 1: runs=$(runs) rms=$(rms)"

run pull 0 >/dev/null 2>&1 && fail "pull error must fail"
[ "$(runs)" = 1 ] && [ "$(rms)" = 0 ] || fail "case 2: runs=$(runs) rms=$(rms)"

run port 99 >/dev/null 2>&1 && fail "persistent bind error must fail"
[ "$(runs)" = 5 ] || fail "case 3: runs=$(runs)"

# Slow docker: the bind error is printed late, right before exit. Detection
# must not depend on timing.
sed -i 's|^if \[ "\$n" -le|[ "${STUB_SLOW:-}" ] \&\& sleep 1\nif [ "$n" -le|' "$TMP/bin/docker"
STUB_SLOW=1 run port 1 >/dev/null 2>&1 || fail "slow bind error must still be detected and retried"
[ "$(runs)" = 2 ] && [ "$(rms)" = 1 ] || fail "case 4: runs=$(runs) rms=$(rms)"

echo "ok"
