#!/usr/bin/env bash
#
# MCP OAuth + protocol conformance — runs real handshakes against a deployed
# Engram authorization server, the same ones Claude Desktop, Claude Code and
# ChatGPT perform.
#
# WHY THIS EXISTS
#
# On 2026-08-04 every Claude connect failed with `invalid_client`, and our unit
# suite was 100% green throughout. The CIMD fixture was three fields long and
# had been written alongside the validator it was testing, so it could only ever
# assert that our code accepts what our code expects. This runs somebody else's
# client against us instead.
#
# WHAT THE FIRST VERSION STILL MISSED
#
# It ran, it passed, and two spec violations sat underneath it (2026-08-05):
# no RFC 9728 §5.1 `WWW-Authenticate` on the 401, and no protected-resource
# metadata at the RFC 9728 §3.1 path. MCPJam did not care — it guesses the
# well-known convention, falls back, and moves on. It is a CLIENT COMPATIBILITY
# tester: its question is "can I connect", not "are you compliant". Anything the
# spec mandates but a generous client tolerates has to be asserted by us, which
# is what STAGE 1 below does.
#
# It also passed `--conformance-checks` (documented as negative checks "after
# the main flow") and ran `protocol conformance` not at all. The former produced
# zero checks, because our flow cannot complete headlessly; the latter skips 29
# of its 32 checks without a bearer token. Both are addressed below.
#
# See docs/context/cimd-vs-dcr-validation-policy.md.
#
# CONSENT: our authorization endpoint requires a Clerk session, so the OAuth
# flow cannot complete headlessly and everything from `received_authorization_code`
# onward is expected to fail there. Every step STAGE 2 exists to protect happens
# BEFORE consent. Driving consent needs Playwright and belongs in the e2e job.
#
# Usage:
#   scripts/mcp-conformance.sh                                  # staging
#   scripts/mcp-conformance.sh https://mcp.engram.page/api/mcp  # explicit target
#
# Env:
#   ENGRAM_CONFORMANCE_TOKEN  bearer token for STAGE 3. An Engram API key
#                             (`engram_...`) works — Plugs.Auth accepts one as a
#                             Bearer. REQUIRED: without it 29 of 32 protocol
#                             checks skip, and a suite that reports on checks it
#                             never ran is the whole failure mode we are here to
#                             prevent.
set -euo pipefail

# Pinned deliberately. The npm package carries registry signatures but NO build
# provenance attestation, so the tarball is not cryptographically tied to a
# commit. `@latest` would let a compromised publish reach CI with network access
# to our auth server. Bump this line consciously.
CLI_VERSION="3.18.0"

TARGET_URL="${1:-https://staging.engram.page/api/mcp}"
ORIGIN="${TARGET_URL%/api/mcp}"
OUT_DIR="${CONFORMANCE_OUT_DIR:-./conformance-results}"
GRADERS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"
mkdir -p "$OUT_DIR"

# Every protocol version the CLI implements. NOT pinned to one, and emphatically
# not left unset: `protocol conformance` defaults to "legacy (2025-era)
# behavior", which is the WEAKEST setting available, so omitting the flag buys
# less coverage rather than more. Clients in the wild negotiate all of these.
PROTOCOL_VERSIONS=(2025-03-26 2025-06-18 2025-11-25 2026-07-28)

# Which stages to run. `spec` and `protocol` work against any target including
# a loopback CI stack, so they are the per-PR gate. `oauth` needs a publicly
# addressed deployment (see STAGE 2's header) and runs against staging.
#
#   CONFORMANCE_STAGES=spec,protocol   per-PR gate (CI stack)
#   CONFORMANCE_STAGES=all             everything (staging/prod)
STAGES="${CONFORMANCE_STAGES:-all}"
case ",$STAGES," in *,all,*|*,oauth,*) RUN_OAUTH_STAGE=1 ;; *) RUN_OAUTH_STAGE=0 ;; esac
case ",$STAGES," in *,all,*|*,spec,*) RUN_SPEC_STAGE=1 ;; *) RUN_SPEC_STAGE=0 ;; esac
case ",$STAGES," in *,all,*|*,protocol,*) RUN_PROTOCOL_STAGE=1 ;; *) RUN_PROTOCOL_STAGE=0 ;; esac

# A stage list that selects nothing would exit 0 having graded nothing — the
# vacuous pass this script exists to prevent, reachable by typo.
if [ "$RUN_OAUTH_STAGE$RUN_SPEC_STAGE$RUN_PROTOCOL_STAGE" = "000" ]; then
  echo "CONFORMANCE_STAGES='$STAGES' selected no stages. Valid: all, spec, oauth, protocol." >&2
  exit 2
fi

# `--no-telemetry`: the CLI ships posthog-node and is opt-out, not opt-in. Their
# docs say it excludes URLs, tokens and headers, and that reads honest — but CI
# runs against our production-shaped auth server and does not need to phone
# anywhere.
#
# `--conformance-checks` is deliberately ABSENT. It runs negative checks *after*
# the main flow completes, and ours cannot complete without a human at a Clerk
# form, so it contributed exactly zero checks while implying coverage. Restore
# it if and when consent is driven from Playwright.
COMMON=(--no-telemetry --auth-mode headless)

FAILED=0

# ── PREFLIGHT ──────────────────────────────────────────────────────────────
# This job runs on an isolated self-hosted runner and reaches both npmjs.org and
# the target through Cloudflare — for staging that is a hairpin back into the
# same physical host. When either leg is down, the CLI fails at step one and the
# run looks exactly like "the authorization server is broken". Distinguishing an
# infrastructure failure from a conformance failure after the fact costs far
# more than checking first. Exit 2 means ENVIRONMENT, and the CI job keys on it
# so a DNS blip does not open "the auth server is broken".
echo "==> preflight"
if ! curl -fsS --max-time 15 -o /dev/null https://registry.npmjs.org/@mcpjam/cli; then
  echo "    ENVIRONMENT: cannot reach the npm registry — not a conformance result." >&2
  exit 2
fi
if ! curl -fsS --max-time 15 -o /dev/null "$ORIGIN/.well-known/oauth-authorization-server"; then
  echo "    ENVIRONMENT: cannot reach $TARGET_URL — not a conformance result." >&2
  exit 2
fi
echo "    npm and $TARGET_URL reachable"

# ── STAGE 1: our own spec assertions ───────────────────────────────────────
# The things the MCP spec MANDATES and MCPJam tolerates. All unauthenticated and
# plain curl, so they grade fully regardless of the consent gate AND against a
# loopback target — the only stage true of both, which is what makes it the
# backbone of the per-PR gate. All three 2026-08-05 discovery bugs were caught
# here, and all three were live while the MCPJam matrix was green.
spec_fail() { echo "    SPEC VIOLATION: $*"; FAILED=1; }

if [ "$RUN_SPEC_STAGE" = "1" ]; then
echo "==> spec assertions (RFC 9728) against $TARGET_URL"

challenge=$(curl -sS -D - -o /dev/null --max-time 15 -X POST \
  -H 'Content-Type: application/json' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' \
  "$TARGET_URL" | tr -d '\r' | grep -i '^www-authenticate:' || true)

metadata_url=""
if [ -z "$challenge" ]; then
  # RFC 9728 §5.1 / MCP 2025-06-18+. Without it a spec-following client has no
  # discovery entry point at all; only clients that additionally guess the
  # well-known path convention connect.
  spec_fail "401 on $TARGET_URL carries no WWW-Authenticate header"
else
  echo "    401 challenge: ${challenge#*: }"
  metadata_url=$(printf '%s' "$challenge" | sed -n 's/.*resource_metadata="\([^"]*\)".*/\1/p')
  [ -n "$metadata_url" ] || spec_fail "WWW-Authenticate present but carries no resource_metadata parameter"
fi

# A pointer to a 404 is worse than no pointer — the client stops instead of
# falling back. Follow it for real, and check the document points back at the
# URL we dialed, since strict clients abort on that mismatch.
if [ -n "$metadata_url" ]; then
  if ! doc=$(curl -fsS --max-time 15 "$metadata_url"); then
    spec_fail "resource_metadata points at $metadata_url which does not resolve"
  else
    advertised=$(printf '%s' "$doc" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("resource",""))')
    echo "    resource_metadata -> $metadata_url (resource=$advertised)"
    if [ -z "$advertised" ]; then
      spec_fail "$metadata_url has no \`resource\` field"
    else
      # `mcp.engram.page` legitimately advertises the BARE host (HostRewrite
      # serves MCP at `/`, see #634), so accept the dialed URL or its origin.
      case "$advertised" in
        "$TARGET_URL"|"$ORIGIN") ;;
        *) spec_fail "advertised resource '$advertised' matches neither $TARGET_URL nor $ORIGIN" ;;
      esac
    fi
  fi
fi

# RFC 9728 §3.1: metadata for a resource WITH a path lives at the well-known
# segment inserted BEFORE that path. Asserted independently of the challenge
# above, because a client may derive this URL itself rather than follow a header.
if [ "$TARGET_URL" != "$ORIGIN" ]; then
  path_scoped="$ORIGIN/.well-known/oauth-protected-resource${TARGET_URL#"$ORIGIN"}"
  if ! curl -fsS --max-time 15 -o /dev/null "$path_scoped"; then
    spec_fail "RFC 9728 §3.1 location $path_scoped does not resolve"
  else
    echo "    §3.1 path-scoped metadata resolves"
  fi
fi

[ "$FAILED" -eq 0 ] && echo "    all spec assertions passed"
fi  # RUN_SPEC_STAGE

# ── STAGE 2: OAuth conformance, full matrix ────────────────────────────────
# Both registration paths across every protocol version. DCR and CIMD are
# genuinely different code in our AS and the CIMD one is newer and less
# travelled; `cimd` uses MCPJam's own published metadata document, which
# declares a device_code grant we do not implement and lists 14 redirect URIs.
# Both were fatal before #1241, and neither has anything to do with whether
# MCPJam can safely use us.
#
# CANNOT RUN AGAINST A LOOPBACK OR PRIVATE TARGET — and not by our choice.
# MCPJam's SDK ships an SSRF guard (`assertOutboundOAuthUrlAllowed`) that
# refuses outbound OAuth metadata fetches to RFC 6890 special-use addresses
# unless the caller opts in, and the CLI exposes no such flag in 3.18.0 or
# 3.19.0:
#
#   Refusing outbound OAuth fetch to loopback host "localhost" (no loopback opt-in)
#
# It is defending against a hostile MCP server steering a fetch at
# 169.254.169.254 or a LAN service — a guard worth having. The consequence for
# us is structural: this stage needs a real, publicly-addressed deployment, so
# it cannot gate a PR against a CI stack. Stages 1 and 3 have no such
# restriction and are the per-PR gate; this one runs against staging on deploy.
if [ "$RUN_OAUTH_STAGE" != "1" ]; then
  echo "==> oauth matrix SKIPPED (stages=$STAGES)"
fi

for strategy in dcr cimd; do
  [ "$RUN_OAUTH_STAGE" = "1" ] || break
  # Cells the CLI declines (CIMD did not exist before 2025-11-25) are N/A, not
  # failures. But a strategy that graded NOTHING across the whole matrix means
  # we tested it nowhere — the same "reported on work it never did" hazard as a
  # skipped protocol check — so that is a hard failure.
  graded=0

  for version in "${PROTOCOL_VERSIONS[@]}"; do
    label="$strategy@$version"
    echo "==> oauth $label"

    # The exit code is deliberately NOT the verdict, and `|| true` is
    # load-bearing rather than sloppy. The CLI exits non-zero unless the WHOLE
    # flow completes, which it cannot here. An earlier revision branched on the
    # exit code and reported a clean pass against a server we knew was broken.
    # The grader below is the only verdict, and it runs every time.
    npx -y "@mcpjam/cli@${CLI_VERSION}" oauth conformance \
        --url "$TARGET_URL" \
        --protocol-version "$version" \
        --registration "$strategy" \
        "${COMMON[@]}" \
        > "$OUT_DIR/oauth-$strategy-$version.json" 2>&1 || true

    rc=0
    python3 "$GRADERS/grade_oauth_conformance.py" \
      "$OUT_DIR/oauth-$strategy-$version.json" "$label" || rc=$?

    case "$rc" in
      0) graded=$((graded + 1)) ;;
      2) ;;                                     # N/A — grader already said so
      *) graded=$((graded + 1)); FAILED=1 ;;    # a real verdict, and it is bad
    esac
  done

  if [ "$graded" -eq 0 ]; then
    echo "    NO SIGNAL — $strategy: every protocol version was declined, so this"
    echo "    strategy was never actually tested. Check the CLI flags."
    FAILED=1
  fi
done

# ── STAGE 3: protocol conformance, full matrix ─────────────────────────────
# 32 checks covering handshake, capability consistency, tool-schema validity,
# SSE behavior, header mismatches, and localhost rebinding rejection. 29 of them
# skip without a bearer token, so unauthenticated this stage grades nothing —
# and a stage reporting on checks it never ran is precisely the failure mode
# this script exists to prevent.
if [ "$RUN_PROTOCOL_STAGE" != "1" ]; then
  echo "==> protocol SKIPPED (stages=$STAGES)"
elif [ -z "${ENGRAM_CONFORMANCE_TOKEN:-}" ]; then
  echo "==> protocol: NO TOKEN"
  echo "    ENGRAM_CONFORMANCE_TOKEN is unset, so 29 of 32 protocol checks would"
  echo "    skip and this stage would grade nothing. Failing rather than"
  echo "    reporting a pass it did not earn. Mint an Engram API key on the"
  echo "    target and set it as the ENGRAM_CONFORMANCE_TOKEN secret."
  FAILED=1
else
  graded=0
  for version in "${PROTOCOL_VERSIONS[@]}"; do
    echo "==> protocol @$version"
    # stderr goes to its OWN file, not into the JSON. `2>&1` here corrupted the
    # report: the CLI writes advisory lines ("server does not advertise
    # resources capability...") that landed ahead of the document and made it
    # unparseable, which the grader then reported as NO SIGNAL. The warnings are
    # still kept — they are useful when a check fails — just not inline.
    npx -y "@mcpjam/cli@${CLI_VERSION}" protocol conformance \
        --url "$TARGET_URL" \
        --protocol-version "$version" \
        --access-token "$ENGRAM_CONFORMANCE_TOKEN" \
        --no-telemetry --reporter json-summary \
        > "$OUT_DIR/protocol-$version.json" \
        2> "$OUT_DIR/protocol-$version.stderr.log" || true

    rc=0
    python3 "$GRADERS/grade_protocol_conformance.py" \
      "$OUT_DIR/protocol-$version.json" "$version" || rc=$?

    case "$rc" in
      0) graded=$((graded + 1)) ;;
      2) ;;                                   # N/A — we do not implement it
      *) graded=$((graded + 1)); FAILED=1 ;;
    esac
  done

  if [ "$graded" -eq 0 ]; then
    echo "    NO SIGNAL — protocol: no version produced a verdict, so this stage"
    echo "    graded nothing at all."
    FAILED=1
  fi
fi

exit "$FAILED"
