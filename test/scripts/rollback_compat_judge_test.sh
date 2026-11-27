#!/usr/bin/env bash
# test/scripts/rollback_compat_judge_test.sh
#
# Guards ci/rollback-compat/judge-migrations.sh, the phase-3 data migration
# verdict of .github/workflows/rollback-compat.yml. Run 45961028308 passed
# with 1 of 20 migrations judged: a helper inside the loop read its stdin.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
. "$ROOT/ci/rollback-compat/judge-migrations.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

ALLOW="$TMP/allow.txt"
printf '%s\n' '* b skipped-done-noreverify reason b' '* c skipped-done-noreverify reason c' > "$ALLOW"
OUT=$'MIGRATIONS_TOTAL=3\nMIGRATION a done v1\nMIGRATION b skipped-done-noreverify v1\nMIGRATION c skipped-done-noreverify v2\nMIGRATIONS_END'

FAILS="$TMP/fails"
fail() { echo "$1" >> "$FAILS"; }
run() { : > "$FAILS"; judge_migrations "$OUT" "$ALLOW" prod >/dev/null; }
die() { echo "FAIL: $*" >&2; exit 1; }

# Green: a well-behaved helper, every ledger closed.
sql() { echo 1; }
run; [ ! -s "$FAILS" ] || die "clean run reported: $(cat "$FAILS")"
echo "ok: clean run passes"

# Red: a helper that reads the loop's stdin (dc exec -T without </dev/null).
sql() { cat >/dev/null; echo 1; }
run; grep -q 'judged 2 of 3' "$FAILS" || die "a truncated loop passed: $(cat "$FAILS")"
echo "ok: a truncated loop fails the count guard"

# Red: a skip on an open ledger.
sql() { echo 0; }
run; grep -q 'ledger row is not closed' "$FAILS" || die "open ledger passed"
echo "ok: a skip on an open ledger fails"

# Red: the ledger read itself fails.
sql() { return 1; }
run; grep -q 'ledger read failed' "$FAILS" || die "failed ledger read passed"
echo "ok: a failed ledger read fails"

# Red: a result the allowlist does not name.
sql() { echo 1; }
OUT=${OUT/MIGRATION a done/MIGRATION a more}
run; grep -q 'a ended more' "$FAILS" || die "unlisted :more passed"
echo "ok: an unlisted result fails"
echo "rollback-compat judge: all tests passed"
