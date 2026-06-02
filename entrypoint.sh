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

/app/bin/engram eval "Engram.Release.prepare_database()"
/app/bin/engram eval "Engram.Release.migrate()"

exec "$@"
