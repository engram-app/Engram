#!/usr/bin/env bash
#
# test-local.sh — run the backend ExUnit suite locally, fast.
#
# Runs `mix test` against a local Postgres (the `backend-postgres-1` docker
# container on :5432, creds engram/engram — the defaults baked into
# config/test.exs). The `test` mix alias self-bootstraps the DB
# (ecto.create -> engram.prepare_database -> ecto.migrate -> test), so this
# wrapper only handles the things that bite you otherwise:
#
#   * worktrees hardlink deps/ from the parent checkout, which carries the
#     PARENT branch's mix.lock — a `deps.get` reconciles it to THIS tree's lock
#     (skipped when already in sync, so it's cheap).
#   * a stray DATABASE_URL in the shell overrides the localhost:5432 test
#     defaults and silently points the suite at the wrong DB — we unset it.
#   * Postgres must actually be reachable before mix tries to connect.
#
# Usage:
#   scripts/test-local.sh                       # whole suite
#   scripts/test-local.sh test/engram/foo_test.exs[:42]   # a file / line
#   scripts/test-local.sh --teardown            # drop the test DB after the run
#   scripts/test-local.sh --reset -- test/...   # drop+recreate test DB first
#
# Flags (must come before a literal `--`, or are sniffed from anywhere):
#   --teardown   drop engram_test after the run (leaves the container alone)
#   --reset      drop the test DB before running (forces a clean schema)
# Everything else is passed straight through to `mix test`.
#
set -euo pipefail

# Resolve the backend checkout this script lives in (works from any worktree).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
cd "$REPO_DIR"

PG_HOST="${PGHOST:-localhost}"
PG_PORT="${PGPORT:-5432}"

teardown=0
reset=0
mix_args=()
for arg in "$@"; do
  case "$arg" in
    --teardown) teardown=1 ;;
    --reset)    reset=1 ;;
    --)         ;; # separator, ignore
    *)          mix_args+=("$arg") ;;
  esac
done

# config/test.exs reads DATABASE_URL first; a stray one silently wins.
unset DATABASE_URL

echo "==> repo: $REPO_DIR"

# 1. Postgres reachable? (bash /dev/tcp avoids a hard dep on pg_isready/nc.)
if ! timeout 3 bash -c "exec 3<>/dev/tcp/$PG_HOST/$PG_PORT" 2>/dev/null; then
  echo "ERROR: Postgres not reachable at $PG_HOST:$PG_PORT." >&2
  echo "       Start the dev DB, e.g.:  docker start backend-postgres-1" >&2
  exit 1
fi
echo "==> postgres ok at $PG_HOST:$PG_PORT"

# 2. Reconcile deps to THIS tree's lock (no-op when already satisfied).
mix deps.get >/dev/null

# 3. Optional pre-run reset for a guaranteed-clean schema.
if [ "$reset" = 1 ]; then
  echo "==> dropping test DB (reset)"
  MIX_ENV=test mix ecto.drop --quiet || true
fi

# 4. Run. The `test` alias creates+prepares+migrates idempotently first.
echo "==> mix test ${mix_args[*]:-(full suite)}"
status=0
MIX_ENV=test mix test "${mix_args[@]}" || status=$?

# 5. Optional teardown — drop the test DB only (never touches the container,
#    which is shared with dev). The sandbox already reverts per-test data, so
#    this is just for leaving zero schema behind.
if [ "$teardown" = 1 ]; then
  echo "==> dropping test DB (teardown)"
  MIX_ENV=test mix ecto.drop --quiet || true
fi

exit "$status"
