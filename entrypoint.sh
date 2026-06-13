#!/bin/sh
# Container entrypoint: cluster bootstrap → migrations → exec the release.
#
# `prepare_database` is cluster-scoped + idempotent: creates the
# `engram_app` role and sets DEFAULT PRIVILEGES on CURRENT_USER's
# future objects. Must run before migrate because the baseline
# migration's structure dump references engram_app in GRANT
# statements.
#
# `exec "$@"` replaces this shell with the BEAM so SIGTERM/SIGINT
# reach the runtime directly (graceful shutdown). Without `exec`,
# signals would terminate the shell while leaving BEAM as a zombied
# child.
#
# `set -e` aborts on any failure — better to crash-loop visibly than
# start a Phoenix node against a half-prepared cluster.
set -e

# One-shot PG18/uuidv7 cutover heal. Only fires when explicitly opted in AND
# the schema is in the broken legacy integer-PK state (self-disabling — see
# Engram.Release.reset_baseline/0). Used once to recover prod after the RDS
# was upgraded PG17→PG18 in-place instead of wiped; the flag is removed from
# the task definition afterwards. Runs before prepare_database/migrate because
# it rebuilds the schema those then operate on.
if [ "${ENGRAM_DB_RESET_BASELINE:-}" = "true" ]; then
  echo "[entrypoint] ENGRAM_DB_RESET_BASELINE=true — running one-shot baseline reset"
  /app/bin/engram eval "Engram.Release.reset_baseline()"
fi

/app/bin/engram eval "Engram.Release.prepare_database()"
/app/bin/engram eval "Engram.Release.migrate()"

# Fail-loud schema-baseline guard. If the DB silently kept its legacy
# integer-PK shape (an in-place engine upgrade that skipped the baseline
# replay — the 2026-06-11 incident), this exits non-zero with an actionable
# message HERE, instead of the BEAM crash-looping on a cryptic Ecto.UUID
# load error during boot. set -e turns the non-zero eval into a clean abort.
/app/bin/engram eval "Engram.Release.verify_schema_baseline()"

exec "$@"
