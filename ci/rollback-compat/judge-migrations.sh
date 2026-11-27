# Phase 3 verdict on run-migrations.exs output, shared by every pair.
# Sourced; needs sql and fail (rbc-lib.sh). Usage:
#   judge_migrations RPC_OUTPUT ALLOWLIST SHAPE
# Every MIGRATION line must end `done`, or be a skip on a closed ledger row
# (read from data_migrations, not the runner's cache) that the allowlist
# names with a reason, or be on the allowlist. The loop must reach a verdict
# for every migration the runner listed: a helper that read the loop's stdin
# once cut it short after one line and the run passed (delta review 6).

judge_migrations() {
  local out="$1" allow="$2" shape="$3"
  local total verdicts=0 name class ver short n reason
  total=$(grep -oE '^MIGRATIONS_TOTAL=[0-9]+' <<<"$out" | cut -d= -f2)
  while read -r _ name class ver; do
    verdicts=$((verdicts + 1))
    short=${name%%:*}
    if [ "$class" = done ]; then echo "  $short: done"; continue; fi
    if [ "$class" = skipped-done-noreverify ]; then
      # A skip is benign only on a closed ledger.
      if ! n=$(sql "SELECT count(*) FROM data_migrations WHERE name = '$name' AND version >= ${ver#v} AND completed_at IS NOT NULL"); then
        fail "ledger read failed for OLD data migration $short"
        continue
      fi
      if [ "${n:-0}" -lt 1 ]; then
        fail "OLD data migration $short was skipped as done, but its ledger row is not closed"
        continue
      fi
    fi
    reason=$(awk -v s="$shape" -v n="$short" -v c="$class" '$1 !~ /^#/ && ($1 == s || $1 == "*") && $2 == n && $3 == c {$1=$2=$3=""; sub(/^ +/, ""); print; exit}' "$allow" 2>/dev/null)
    if [ -n "$reason" ]; then
      echo "  $short: $class (allowed: $reason)"
    else
      fail "OLD data migration $short ended $class, not done and not on $allow"
    fi
  done < <(grep '^MIGRATION ' <<<"$out")
  echo "migration verdicts: $verdicts of ${total:-?}"
  [ -n "$total" ] && [ "$verdicts" -eq "$total" ] \
    || fail "the verdict loop judged $verdicts of ${total:-?} migrations"
  # Allowlist lines no result used: dead reasons must not carry forward.
  awk -v s="$shape" '$1 !~ /^#/ && NF >= 3 && ($1 == s || $1 == "*") {print $2, $3}' "$allow" | while read -r n c; do
    grep -qE "^MIGRATION ${n//./\\.}(:[^ ]*)? $c( |$)" <<<"$out" || echo "::warning::unused migrations-allow line: $n $c"
  done
}
