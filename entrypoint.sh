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

# Two logins, one container.
#
# The bootstrap + migration steps below need a POWERFUL role: CREATEROLE to
# create `engram_app`, GRANT on the schema, and DDL for migrations. The app
# pool wants the exact opposite — a restricted role, so Postgres row-level
# security actually applies to it.
#
# A single DATABASE_URL cannot be both, and that is the reason RLS has never
# been enforced in ANY environment: every deployment connects as its migrator
# role (`engram` on FastRaid, `engram_admin` on RDS, the cluster superuser
# locally), and a migrator either owns the tables or holds BYPASSRLS, so the
# policies never bite. The tables carry FORCE ROW LEVEL SECURITY and it has
# simply never applied to the connection making the queries.
#
# MIGRATOR_DATABASE_URL is that seam. Scoped PER COMMAND below — deliberately
# NOT exported — so only these evals see the admin login, while the BEAM that
# `exec`s at the bottom inherits the unmodified DATABASE_URL and runs as the
# restricted role. Exporting it once here instead would look tidier and put
# the entire app back on the admin login; `test/engram/entrypoint_test.exs`
# pins against exactly that.
#
# Unset — prod, CI, local dev — it falls back to DATABASE_URL and behaviour is
# byte-for-byte unchanged. `config/runtime.exs` reads DATABASE_URL through
# `System.get_env/1`, and releases load runtime config for `eval` too, so the
# per-command override needs no Elixir-side plumbing.
MIGRATOR_DATABASE_URL="${MIGRATOR_DATABASE_URL:-$DATABASE_URL}"

# One-shot PG18/uuidv7 cutover heal. Only fires when explicitly opted in AND
# the schema is in the broken legacy integer-PK state (self-disabling — see
# Engram.Release.reset_baseline/0). Used once to recover prod after the RDS
# was upgraded PG17→PG18 in-place instead of wiped; the flag is removed from
# the task definition afterwards. Runs before prepare_database/migrate because
# it rebuilds the schema those then operate on.
if [ "${ENGRAM_DB_RESET_BASELINE:-}" = "true" ]; then
  echo "[entrypoint] ENGRAM_DB_RESET_BASELINE=true — running one-shot baseline reset"
  DATABASE_URL="$MIGRATOR_DATABASE_URL" /app/bin/engram eval "Engram.Release.reset_baseline()"
fi

DATABASE_URL="$MIGRATOR_DATABASE_URL" /app/bin/engram eval "Engram.Release.prepare_database()"
DATABASE_URL="$MIGRATOR_DATABASE_URL" /app/bin/engram eval "Engram.Release.migrate()"

# Fail-loud schema-baseline guard. If the DB silently kept its legacy
# integer-PK shape (an in-place engine upgrade that skipped the baseline
# replay — the 2026-06-11 incident), this exits non-zero with an actionable
# message HERE, instead of the BEAM crash-looping on a cryptic Ecto.UUID
# load error during boot. set -e turns the non-zero eval into a clean abort.
DATABASE_URL="$MIGRATOR_DATABASE_URL" /app/bin/engram eval "Engram.Release.verify_schema_baseline()"

# NOT prefixed, and that is the whole point: the BEAM runs with the
# unmodified DATABASE_URL, i.e. the restricted role.
exec "$@"
