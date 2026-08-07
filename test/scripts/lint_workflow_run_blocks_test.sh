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

echo "All tests passed (6)."
