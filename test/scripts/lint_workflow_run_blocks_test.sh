#!/usr/bin/env bash
# test/scripts/lint_workflow_run_blocks_test.sh
#
# Proves the linter actually catches the failure mode it exists for, and
# does not cry wolf on the shell forms our workflows legitimately use.
set -euo pipefail

LINTER="$(cd "$(dirname "$0")" && pwd)/../../scripts/lint_workflow_run_blocks.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# --- Test 1: the real bug — a comment inside a continued command ---
cat > "$TMP/bad.yml" <<'YML'
name: bad
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - name: comment inside a continuation
        run: |
          curl -sS \
            # this comment breaks the command
            --data "x" \
            "$URL"
YML
if python3 "$LINTER" "$TMP/bad.yml" >/dev/null 2>&1; then
  fail "Test 1: linter passed a comment-inside-continuation (the bug it exists for)"
fi

# --- Test 2: unbalanced quote ---
cat > "$TMP/bad2.yml" <<'YML'
name: bad2
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "unterminated
YML
python3 "$LINTER" "$TMP/bad2.yml" >/dev/null 2>&1 && fail "Test 2: linter passed an unterminated string"

# --- Test 3: GitHub expressions must not be treated as shell ---
# ${{ }} is substituted before the shell runs; a bare parse would choke.
cat > "$TMP/expr.yml" <<'YML'
name: expr
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          echo "${{ secrets.FOO }}"
          if [ "${{ github.ref }}" = "refs/heads/main" ]; then echo hi; fi
YML
python3 "$LINTER" "$TMP/expr.yml" >/dev/null 2>&1 || fail "Test 3: false positive on GitHub expressions"

# --- Test 4: ${VAR:0:${#OTHER}} must NOT be mistaken for an expression ---
# This is the false positive a naive `}}` -> `}` replace produces; it exists
# verbatim in engram-infra's health-check step.
cat > "$TMP/brace.yml" <<'YML'
name: brace
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          RUNNING=abcdef1234
          EXPECTED=abcdef1
          if [ "${RUNNING:0:${#EXPECTED}}" = "$EXPECTED" ]; then echo match; fi
YML
python3 "$LINTER" "$TMP/brace.yml" >/dev/null 2>&1 || fail "Test 4: false positive on \${VAR:0:\${#OTHER}}"

# --- Test 5: non-bash shells are skipped, not parsed as bash ---
cat > "$TMP/py.yml" <<'YML'
name: py
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - shell: python
        run: |
          x = {"a": 1}
          print(f"{x['a']}")
YML
python3 "$LINTER" "$TMP/py.yml" >/dev/null 2>&1 || fail "Test 5: python step parsed as bash"

# --- Test 6: a clean bash block passes ---
cat > "$TMP/good.yml" <<'YML'
name: good
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          set -euo pipefail
          # a comment on its own line is fine
          curl -sS \
            --data "x" \
            "$URL"
YML
python3 "$LINTER" "$TMP/good.yml" >/dev/null 2>&1 || fail "Test 6: false positive on a clean block"

# --- Test 7: piping into grep -q under pipefail (Actions bash is -eo pipefail) ---
# grep -q exits on the first match; the producer's next write hits EPIPE and
# pipefail fails the pipeline. Timing-dependent, so it flakes rather than fails.
cat > "$TMP/pipegrep.yml" <<'YML'
name: pipegrep
on: push
jobs:
  j:
    runs-on: ubuntu-latest
    steps:
      - run: |
          if printf '%s' "$msg" PIPE grep -qiF 'x'; then echo hit; fi
YML
sed -i 's/PIPE/|/' "$TMP/pipegrep.yml"
python3 "$LINTER" "$TMP/pipegrep.yml" >/dev/null 2>&1 && fail "Test 7: linter passed a pipe into grep -q"

# --- Test 8: same check on plain shell scripts ---
printf '%s\n' 'set -euo pipefail' 'echo "$out" PIPE grep -q foo' | sed 's/PIPE/|/' > "$TMP/bad.sh"
python3 "$LINTER" "$TMP/bad.sh" >/dev/null 2>&1 && fail "Test 8: linter passed a pipe into grep -q in a .sh"

# --- Test 9: the here-string form and a non-quiet grep pipe both pass ---
printf '%s\n' 'set -euo pipefail' 'grep -q foo <<<"$out"' 'echo "$out" PIPE grep -c foo' 'true || grep -q foo /dev/null' | sed 's/PIPE/|/' > "$TMP/good.sh"
python3 "$LINTER" "$TMP/good.sh" >/dev/null 2>&1 || fail "Test 9: false positive on here-string / grep -c / ||"

echo "All tests passed (9)."
