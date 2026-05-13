#!/bin/sh
# Container entrypoint: run migrations, then exec the release.
#
# `exec "$@"` replaces this shell with the BEAM so SIGTERM/SIGINT reach
# the runtime directly (graceful shutdown). Without `exec`, signals
# would terminate the shell while leaving BEAM as a zombied child.
#
# `set -e` aborts on migrate failure — we'd rather fail-fast than start
# a Phoenix node against an unmigrated schema.
set -e

/app/bin/engram eval "Engram.Release.migrate()"

exec "$@"
