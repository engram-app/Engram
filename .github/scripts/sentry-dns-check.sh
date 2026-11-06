#!/usr/bin/env bash
# Warn (never fail) when this runner cannot resolve sentry.io to a real address.
#
# The LAN AdGuard Home filter (10.0.20.253/.254) sinkholes sentry.io to 0.0.0.0.
# Runners whose resolver forwards there (gamingpc-*, minipc-*) then fail every
# Sentry upload. The upload steps are non-fatal, so without this line the only
# trace is a buried "fetch failed" and prod stack traces lose their source maps.
# See docs/context/ci-runner-network-and-disk-gotchas.md section 4.
set -u
host="${1:-sentry.io}"
addrs=$(getent ahosts "$host" | awk '{print $1}' | sort -u | paste -sd, -)
real=$(printf '%s\n' "$addrs" | tr , '\n' | grep -vxE '0\.0\.0\.0|::|' || true)
if [ -z "$real" ]; then
  echo "::warning::${RUNNER_NAME:-this runner} resolves ${host} to '${addrs:-nothing}' (DNS sinkhole). Sentry release/source-map upload will fail. See ci-runner-network-and-disk-gotchas.md section 4."
fi
exit 0
