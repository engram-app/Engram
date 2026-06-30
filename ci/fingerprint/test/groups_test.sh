# ci/fingerprint/test/groups_test.sh
set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
. ci/fingerprint/groups.sh
. ci/fingerprint/compute.sh
fail=0
h=$(group_hash elixir-src otp27); [ -n "$h" ] || { echo "FAIL elixir-src empty"; fail=1; }
[ "$(group_hash elixir-src otp27)" = "$h" ] || { echo "FAIL non-deterministic"; fail=1; }
if group_hash bogus otp27 2>/dev/null; then echo "FAIL bogus accepted"; fail=1; fi
[ "$(group_hash elixir-src otp27)" != "$(group_hash elixir-src otp99)" ] || { echo "FAIL beam not mixed"; fail=1; }
# every job maps only to known groups (+plugin is a sentinel, allowed)
for j in $(job_names); do
  for g in $(job_groups "$j"); do
    [ "$g" = "+plugin" ] && continue
    group_paths "$g" >/dev/null || { echo "FAIL job $j -> unknown group $g"; fail=1; }
  done
done
[ "$fail" = 0 ] && echo "groups_test OK"
exit $fail
