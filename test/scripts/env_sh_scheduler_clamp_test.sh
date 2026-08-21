#!/usr/bin/env bash
# test/scripts/env_sh_scheduler_clamp_test.sh
#
# Proves rel/env.sh's scheduler clamp picks the right pool size for each cgroup
# layout we actually boot on — and, crucially, that it is LOUD when it cannot.
#
# This test exists because the clamp silently did nothing in prod for an unknown
# period. It was written for cgroup-reported quotas, but Fargate enforces CPU on
# the TASK (its microVM), so the container cgroup reports `max`, detection bailed
# down an empty `case` branch, and the BEAM auto-sized to the VM's visible CPUs:
# 2 normal + 2 dirty-CPU schedulers on a 0.5-vCPU task, verified 2026-08-20 via
# `beam_system_schedulers_info`. The only echo sat on the success branch, so
# "clamped" and "gave up" were indistinguishable from outside.
#
# Same failure shape as docs/context/sobelow-silent-no-op-and-fingerprint-skips.md.
# Hence: every case below asserts on the MESSAGE as well as the flags.
set -euo pipefail

ENV_SH="$(cd "$(dirname "$0")" && pwd)/../../rel/env.sh.eex"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Extract just the scheduler block and redirect its cgroup reads at a fixture
# dir. Everything above it (RELEASE_NODE/ENI discovery) needs AWS metadata and
# is out of scope here.
sed -n '/^# Size the scheduler pools/,/^fi$/p' "$ENV_SH" \
  | sed 's#/sys/fs/cgroup#${CGROUP_DIR}#g' > "$TMP/clamp.sh"

sh -n "$TMP/clamp.sh" || fail "extracted clamp block is not valid POSIX sh"

mkdir -p "$TMP/v2" "$TMP/v1/cpu" "$TMP/nolimit"
echo "50000 100000" > "$TMP/v2/cpu.max"                # 0.5 vCPU, cgroup v2
echo "max 100000"   > "$TMP/nolimit/cpu.max"           # Fargate: quota unset
echo "200000" > "$TMP/v1/cpu/cpu.cfs_quota_us"         # 2 vCPU, cgroup v1
echo "100000" > "$TMP/v1/cpu/cpu.cfs_period_us"

# Runs the block in a clean env. Echoes "<flags>|<stderr>".
run_clamp() {
  local cgroup_dir="$1"; shift
  env -i sh -c "
    $*
    CGROUP_DIR='$TMP/$cgroup_dir'
    . '$TMP/clamp.sh' 2>'$TMP/err'
    printf '%s' \"\$ERL_FLAGS\"
  " 2>/dev/null
}
stderr_of() { cat "$TMP/err"; }

# --- 1: cgroup v2 fractional quota rounds UP to one full scheduler ---
got=$(run_clamp v2 "true")
[ "$got" = "+S 1:1 +SDcpu 1:1" ] || fail "1: cgroup v2 0.5 vCPU gave '$got'"

# --- 2: cgroup v1 whole quota ---
got=$(run_clamp v1 "true")
[ "$got" = "+S 2:2 +SDcpu 2:2" ] || fail "2: cgroup v1 2 vCPU gave '$got'"

# --- 3: THE REGRESSION. No readable quota must WARN, not bail silently ---
got=$(run_clamp nolimit "true")
[ -z "$got" ] || fail "3: expected no flags without a quota, got '$got'"
stderr_of | grep -q "WARNING" \
  || fail "3: silent bail — the exact defect this test exists for. stderr: $(stderr_of)"
stderr_of | grep -q "BEAM_SCHEDULERS" \
  || fail "3: warning must name the remedy. stderr: $(stderr_of)"

# --- 4: explicit BEAM_SCHEDULERS works where detection cannot (Fargate) ---
got=$(run_clamp nolimit "BEAM_SCHEDULERS=1; export BEAM_SCHEDULERS")
[ "$got" = "+S 1:1 +SDcpu 1:1" ] || fail "4: BEAM_SCHEDULERS=1 gave '$got'"

# --- 5: explicit wins over a readable cgroup quota ---
got=$(run_clamp v2 "BEAM_SCHEDULERS=4; export BEAM_SCHEDULERS")
[ "$got" = "+S 4:4 +SDcpu 4:4" ] || fail "5: explicit did not override cgroup, got '$got'"

# --- 6: junk falls back to detection rather than exporting nonsense ---
for junk in abc 0 -2 "1 2"; do
  got=$(run_clamp v2 "BEAM_SCHEDULERS='$junk'; export BEAM_SCHEDULERS")
  [ "$got" = "+S 1:1 +SDcpu 1:1" ] \
    || fail "6: BEAM_SCHEDULERS='$junk' should fall back to cgroup, got '$got'"
  stderr_of | grep -q "ignoring BEAM_SCHEDULERS" \
    || fail "6: rejecting '$junk' must say so. stderr: $(stderr_of)"
done

# --- 7: a pre-set ERL_FLAGS is never clobbered ---
got=$(run_clamp v2 "ERL_FLAGS='+S 8:8'; export ERL_FLAGS")
[ "$got" = "+S 8:8" ] || fail "7: pre-set ERL_FLAGS was overwritten, got '$got'"

# --- 8: never exits non-zero, on any path (it runs on EVERY boot) ---
for dir in v2 v1 nolimit; do
  env -i sh -c "CGROUP_DIR='$TMP/$dir'; . '$TMP/clamp.sh'" >/dev/null 2>&1 \
    || fail "8: clamp exited non-zero for $dir — this file runs on every boot"
done

echo "PASS: env.sh scheduler clamp (8 cases)"
