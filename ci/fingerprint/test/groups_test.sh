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

# INPUT COVERAGE: a job's marker key must include EVERY file that job reads.
# A path outside the key means a stale marker can skip a check the edit was
# supposed to re-run — and config files fail OPEN (they can only loosen a
# rule), so the miss is silent and permanent. Each pair below is a step that
# actually consumes that path in verify.yml; grep the step name to confirm.
job_covers() { # <job> <path> -> 0 if path appears in any of the job's groups
  local job="$1" want="$2" g p
  for g in $(job_groups "$job"); do
    [ "$g" = "+plugin" ] && continue
    for p in $(group_paths "$g"); do
      [ "$p" = "$want" ] && return 0
    done
  done
  return 1
}
# job:path pairs — "<job> <path> <verify.yml step that reads it>"
while read -r job path step; do
  [ -z "$job" ] && continue
  job_covers "$job" "$path" || { echo "FAIL $job hash omits $path (read by: $step)"; fail=1; }
done <<'PAIRS'
unit-tests openapi.json OpenAPI-spec-drift-gate
unit-tests .squawk.toml Lint-new-migrations-squawk
unit-tests priv Lint-DB-schema-splinter
unit-tests test Run-Elixir-unit-tests
lint .credo.exs Credo-strict
lint .dialyzer_ignore.exs Dialyzer
lint .sobelow-conf Sobelow
lint .sobelow-skips Sobelow-accepted-findings
lint mix.lock Hex-CVE-audit-mix_audit
e2e-browser frontend browser-e2e-serves-the-SPA
storage-database Dockerfile boots-the-release-image
PAIRS
[ "$fail" = 0 ] && echo "groups_test OK"
exit $fail
