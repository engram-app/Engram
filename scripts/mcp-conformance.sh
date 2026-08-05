#!/usr/bin/env bash
#
# MCP OAuth conformance — runs real OAuth handshakes against a deployed Engram
# authorization server, the same ones Claude Desktop, Claude Code and ChatGPT
# perform.
#
# WHY THIS EXISTS
#
# On 2026-08-04 every Claude connect failed with `invalid_client`, and our unit
# suite was 100% green throughout. The CIMD fixture was three fields long and
# had been written alongside the validator it was testing, so it could only ever
# assert that our code accepts what our code expects. This runs somebody else's
# client against us instead. Against pre-fix main it fails at exactly one step:
#
#   FAILED received_authorization_code -- HTTP 400 Bad Request
#
# See docs/context/cimd-vs-dcr-validation-policy.md.
#
# CONSENT: our authorization endpoint requires a Clerk session, so the flow
# cannot complete headlessly and everything from `received_authorization_code`
# onward is expected to fail here. That is fine — every step this suite exists
# to protect (discovery, PRM/AS metadata, CIMD fetch + document acceptance, the
# authorization request itself) happens BEFORE consent. Driving consent needs
# Playwright and belongs in the e2e job, not this one.
#
# Usage:
#   scripts/mcp-conformance.sh                                  # staging
#   scripts/mcp-conformance.sh https://mcp.engram.page/api/mcp  # explicit target
set -euo pipefail

# Pinned deliberately. The npm package carries registry signatures but NO build
# provenance attestation, so the tarball is not cryptographically tied to a
# commit. `@latest` would let a compromised publish reach CI with network access
# to our auth server. Bump this line consciously.
CLI_VERSION="3.18.0"

TARGET_URL="${1:-https://staging.engram.page/api/mcp}"
OUT_DIR="${CONFORMANCE_OUT_DIR:-./conformance-results}"
mkdir -p "$OUT_DIR"

# `--no-telemetry`: the CLI ships posthog-node and is opt-out, not opt-in. Their
# docs say it excludes URLs, tokens and headers, and that reads honest — but CI
# runs against our production-shaped auth server and does not need to phone
# anywhere.
COMMON=(--no-telemetry --auth-mode headless --conformance-checks)

# Both registration paths, because they are genuinely different code in our AS
# and the CIMD one is newer and less travelled. `cimd` uses MCPJam's own
# published metadata document, which is the point: it declares a device_code
# grant we do not implement and lists 14 redirect URIs. Both of those were fatal
# before the fix, and neither has anything to do with whether MCPJam can safely
# use us.
FAILED=0

# PREFLIGHT. This job runs on an isolated self-hosted runner and reaches both
# npmjs.org and the target through Cloudflare — for staging that is a hairpin
# back into the same physical host. When either leg is down, the CLI fails at
# step one and the run looks exactly like "the authorization server is broken".
# Distinguishing an infrastructure failure from a conformance failure after the
# fact costs far more than checking first.
echo "==> preflight"
if ! curl -fsS --max-time 15 -o /dev/null https://registry.npmjs.org/@mcpjam/cli; then
  echo "    ENVIRONMENT: cannot reach the npm registry — not a conformance result." >&2
  exit 2
fi
if ! curl -fsS --max-time 15 -o /dev/null "${TARGET_URL%/api/mcp}/.well-known/oauth-authorization-server"; then
  echo "    ENVIRONMENT: cannot reach $TARGET_URL — not a conformance result." >&2
  exit 2
fi
echo "    npm and $TARGET_URL reachable"

for strategy in dcr cimd; do
  echo "==> $strategy against $TARGET_URL"

  # The exit code is deliberately NOT the verdict, and `|| true` is load-bearing
  # rather than sloppy. The CLI exits non-zero unless the WHOLE flow completes,
  # which it cannot here: our authorization endpoint requires a Clerk session and
  # nothing headless can sit through that. An earlier revision of this script
  # branched on the exit code and reported a clean pass against a server we knew
  # was broken. The classifier below is the only verdict, and it runs every time.
  npx -y "@mcpjam/cli@${CLI_VERSION}" oauth conformance \
      --url "$TARGET_URL" \
      --protocol-version 2025-11-25 \
      --registration "$strategy" \
      "${COMMON[@]}" \
      > "$OUT_DIR/$strategy.json" 2>&1 || true

  python3 - "$OUT_DIR/$strategy.json" "$strategy" <<'PY' || FAILED=1
import json, sys

path, strategy = sys.argv[1], sys.argv[2]
try:
    doc = json.load(open(path))
except Exception:
    print(f"    could not parse output for {strategy} — see {path}")
    sys.exit(1)

# Everything from here on needs a human at a Clerk login form.
CONSENT_GATED = {
    "received_authorization_code",
    "token_request",
    "received_tokens",
    "authenticated_mcp_request",
}

# The step NAME is not enough, and getting this wrong once already cost a green
# run against a server we knew was broken.
#
# `received_authorization_code` fails on a HEALTHY server too — the runner has
# no way to sit through a Clerk login. But it failed on the BROKEN server as
# well, for an entirely different reason, and both surface under the same name.
# The distinguishing signal is the HTTP status our authorization endpoint
# returned:
#
#   302 -> we accepted the client and sent it to consent. Healthy; the runner
#          simply cannot go further without a human.
#   400 -> `render_client_error(conn, "invalid_client")`. THE BUG.
#
# So a consent-gated step is excused only when the server did not answer 4xx.
# Anything else is a regression regardless of which step reported it.
def http_status(step):
    resp = (step.get("http") or {}).get("response") or {}
    return resp.get("status")

problems = []
for step in doc.get("steps", []):
    if step.get("status") != "failed":
        continue
    name = step.get("step")
    status = http_status(step)
    msg = (step.get("error") or {}).get("message", "")
    if name not in CONSENT_GATED:
        problems.append((name, status, msg))
    elif status is not None and status >= 400:
        problems.append((name, status, msg))

if problems:
    print(f"    REGRESSION — {strategy}:")
    for name, status, msg in problems:
        print(f"      {name} [HTTP {status}]: {msg[:150]}")
    sys.exit(1)

reached = {s["step"] for s in doc.get("steps", []) if s.get("status") == "passed"}
print(f"    reached the consent gate cleanly ({len(reached)} steps passed)")
sys.exit(0)
PY
done

exit "$FAILED"
