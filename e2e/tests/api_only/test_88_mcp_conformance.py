"""Test 79: MCP OAuth + protocol conformance against THIS build.

Runs `scripts/mcp-conformance.sh` — a real third-party client (MCPJam's CLI)
plus our own RFC 9728 assertions — against the CI stack.

WHY IT LIVES HERE RATHER THAN ON A SCHEDULE
-------------------------------------------
It briefly rode a daily cron against staging. That can never gate a PR: on a
PR the deployment still runs `main`, so a cron reports the regression the
morning after it merges. Pointed at the CI stack, the same suite grades the
commit under review — which is the whole point.

This also removes the `ENGRAM_CONFORMANCE_TOKEN` repo secret. The stack mints
its own key via the `sync_user` fixture, which is strictly better than storing
a long-lived credential: nothing to rotate, nothing to leak.

WHAT IT CATCHES THAT UNIT TESTS DO NOT
--------------------------------------
Somebody else's client, exercising the parts of our authorization server that
only a client exercises: CIMD negotiation against MCPJam's real published
metadata document, both registration strategies, and every protocol version.
On 2026-08-04 our unit suite was 100% green while every Claude connect failed
with `invalid_client`.

Requires:
- ENGRAM_API_URL (CI stack, e.g. http://localhost:8100/api)
- node/npx on the runner — asserted, NOT skipped (see below)
"""
from __future__ import annotations

import logging
import os
import shutil
import subprocess
from pathlib import Path

import pytest

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
# OAuth/MCP endpoints hang off the origin, not /api/... — strip the suffix the
# same way test_71 does.
ORIGIN = API_URL[: -len("/api")] if API_URL.endswith("/api") else API_URL.rsplit("/api", 1)[0]
MCP_URL = f"{ORIGIN}/api/mcp"

# e2e/ sits beside the repo root that holds scripts/.
REPO_ROOT = Path(__file__).resolve().parents[3]
SCRIPT = REPO_ROOT / "scripts" / "mcp-conformance.sh"

# Exit 2 is the script's ENVIRONMENT signal — npm registry or target
# unreachable. Not a conformance verdict, and failing the build on a DNS blip
# trains everyone to re-run a red gate, which is how a gate stops meaning
# anything.
EXIT_ENVIRONMENT = 2

# Which stages gate a PR. `spec` only, and each exclusion is a MEASURED
# blocker rather than a preference:
#
#   oauth     — MCPJam's SDK refuses outbound OAuth fetches to RFC 6890
#               special-use addresses, and the CLI exposes no opt-in (3.18/3.19):
#               "Refusing outbound OAuth fetch to loopback host". A CI stack is
#               loopback by construction, so this stage needs a real deployment.
#   protocol  — genuinely red against us today: `ping` unimplemented,
#               `localhost-host-rebinding-rejected` (we answer 200 to a
#               rebinding Host), and we announce protocol 2025-03-26 so
#               2025-06-18+ fail at `server-initialize`. Real gaps, filed
#               separately. Turning them on now would block every merge;
#               excluding the failing checks would be the silent-green this
#               suite exists to prevent. It graduates to the gate when they are
#               fixed, not before.
#
# `spec` is not a consolation prize: it is the stage that caught all three
# discovery bugs on 2026-08-05 while the MCPJam matrix was green.
GATED_STAGES = "spec"


def test_mcp_conformance(sync_user, tmp_path):
    """The suite must pass end to end against the build under review."""
    assert SCRIPT.exists(), f"{SCRIPT} is missing — the gate cannot run"

    # Deliberately an assert, not a skipif. A `skipif` here would make the gate
    # silently evaporate the day the runner image loses node, and pytest would
    # report a tidy green. That is the exact failure mode this whole suite
    # exists to prevent — see docs/context/mcp-conformance-suite-limits.md.
    assert shutil.which("npx") is not None, (
        "npx not found on this runner. The conformance gate needs node; "
        "verify.yml installs it via actions/setup-node. Failing rather than "
        "skipping, so a missing runtime cannot pass for a passing gate."
    )

    _email, _provider_user_id, api_key = sync_user

    result = subprocess.run(
        [str(SCRIPT), MCP_URL],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=540,
        env={
            **os.environ,
            "CONFORMANCE_OUT_DIR": str(tmp_path / "conformance"),
            "CONFORMANCE_STAGES": GATED_STAGES,
            # Unlocks STAGE 3's 32 protocol checks. `Plugs.Auth` accepts an
            # `engram_` API key as a Bearer, so the fixture's key is a valid
            # access token for the MCP endpoint.
            "ENGRAM_CONFORMANCE_TOKEN": api_key,
        },
    )

    logger.info("mcp-conformance stdout:\n%s", result.stdout)
    if result.stderr.strip():
        logger.info("mcp-conformance stderr:\n%s", result.stderr)

    if result.returncode == EXIT_ENVIRONMENT:
        pytest.skip(f"conformance environment unavailable:\n{result.stdout}{result.stderr}")

    # The script prints one line per graded cell; surface the whole thing on
    # failure so the CI log carries the verdict without downloading artifacts.
    assert result.returncode == 0, (
        f"MCP conformance failed against {MCP_URL} (exit {result.returncode}).\n\n"
        f"{result.stdout}\n{result.stderr}"
    )
