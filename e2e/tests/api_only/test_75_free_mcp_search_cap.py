"""E2E test 75: the Free search cap binds the MCP transport, not just /api/search.

`EnforceSearchCap` is a plug guarded on `request_path: "/api/search"`. MCP tool
calls arrive as a JSON-RPC body at `POST /api/mcp` and reach
`Engram.Search.search/4` directly, so for the whole life of that plug the Free
tier's `external_ai_searches_per_day` was unenforced on the exact client class
its own moduledoc named. See docs/context/mcp-bypasses-path-shaped-plugs.md.

The unit tests for that plug synthesize a conn whose `request_path` is already
`/api/search`, which proves the rule and never the routing. This test proves the
routing against a real server:

  - a Free user's `search_notes` MCP call succeeds while budget remains,
  - the next one comes back as JSON-RPC error -32_005 naming the limit key,
  - `POST /api/search` for the SAME user is refused too — one bucket, two
    transports, so a client cannot launder searches by switching protocol,
  - a non-search MCP tool still works, i.e. we capped searches and not the
    whole server.

Auth is the OAuth device flow (internal JWT), not an API key: Free defaults
`api_rps_cap` to 0 and `api_write_enabled` to false, so an API-key-authed MCP
call is rejected by RequireApiRpsBudget long before reaching the search cap.
Device-flow tokens are the real Free MCP path anyway.
"""
from __future__ import annotations

import asyncio
import logging
import os
import subprocess

import pytest
import requests

from helpers.clerk import ClerkClient
from helpers.oauth import provision_oauth_tokens

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — Clerk auth required for Free MCP search cap test",
)

# Pinned to 1 so the boundary is tight and the test spends one token, not 15.
# DailyCap refills at capacity/86_400 per second, so a capacity of 1 regenerates
# in ~24h — nothing leaks back inside a test run.
SEARCH_BUDGET = 1


def _set_search_cap(clerk_user_id: str, value: int) -> None:
    """Pin external_ai_searches_per_day for one user via an operator override.

    Keyed on `users.external_id` (the Clerk user id) rather than email:
    provision_oauth_tokens mints the email internally and does not return it.
    A DB trigger pg_notifies on user_limit_overrides writes, so OverrideCache
    picks this up without a restart.
    """
    sql = (
        "INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES ((SELECT id FROM users WHERE external_id = '{clerk_user_id}'), "
        f"'external_ai_searches_per_day', '{{\"v\": {value}}}'::jsonb, 'e2e-test', 'e2e') "
        "ON CONFLICT (user_id, key) DO UPDATE "
        "SET value = EXCLUDED.value, set_at = NOW()"
    )
    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"_set_search_cap failed: {result.stderr.strip()}")
    assert "INSERT 0 1" in result.stdout, (
        f"override did not apply (user not found?): {result.stdout.strip()}"
    )


def _mcp_call(token: str, name: str, arguments: dict) -> dict:
    resp = requests.post(
        f"{API_URL}/mcp",
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": name, "arguments": arguments},
        },
        headers={"Authorization": f"Bearer {token}"},
        timeout=15,
    )
    assert resp.status_code == 200, (
        f"MCP transport should answer 200 even for JSON-RPC errors; "
        f"got {resp.status_code}: {resp.text[:300]}"
    )
    return resp.json()


def test_free_mcp_search_cap_binds_and_is_shared_with_rest():
    clerk = ClerkClient(CLERK_SECRET)
    clerk_user_id, tokens = asyncio.run(
        provision_oauth_tokens(clerk, API_URL, label="mcpcap")
    )
    token = tokens["access_token"]
    vault_id = tokens["vault_id"]

    # Stays Free on purpose — provision_oauth_tokens does not call
    # grant_test_plan, so §G defaults hold and the cap under test is real.
    _set_search_cap(clerk_user_id, SEARCH_BUDGET)

    # Seed one note so a successful search has something to match and an empty
    # result cannot be mistaken for a refusal.
    seed = requests.post(
        f"{API_URL}/notes",
        json={
            "path": "Health/Supplements.md",
            "content": "# Supplements\n\nOmega 3 and vitamin D.",
            "mtime": 1000.0,
        },
        headers={"Authorization": f"Bearer {token}", "X-Vault-ID": vault_id},
        timeout=15,
    )
    assert seed.status_code in (200, 201), (
        f"seed note failed: {seed.status_code} {seed.text[:300]}"
    )

    # 1. Budget remains → the tool answers normally.
    first = _mcp_call(token, "search_notes", {"query": "supplements"})
    assert "result" in first, f"first MCP search should succeed; got {first}"
    assert "error" not in first, f"first MCP search should not error; got {first}"

    # 2. Budget spent → JSON-RPC error naming the limit key. Before the fix this
    #    returned a normal result forever: the plug never saw /api/mcp.
    second = _mcp_call(token, "search_notes", {"query": "supplements"})
    assert "error" in second, (
        f"second MCP search must be refused — the Free search cap does not bind "
        f"the MCP transport; got {second}"
    )
    assert second["error"]["code"] == -32_005, (
        f"expected JSON-RPC -32005 rate_limited; got {second['error']}"
    )
    assert "external_ai_searches_per_day" in second["error"]["message"], (
        f"the refusal must name the limit key so clients can route the upgrade "
        f"prompt; got {second['error']['message']}"
    )

    # 3. Same bucket over REST. Switching transport must not buy more searches.
    rest = requests.post(
        f"{API_URL}/search",
        json={"query": "supplements"},
        headers={"Authorization": f"Bearer {token}", "X-Vault-ID": vault_id},
        timeout=15,
    )
    assert rest.status_code == 402, (
        f"POST /api/search must share the MCP bucket; got {rest.status_code}: "
        f"{rest.text[:300]}"
    )
    body = rest.json()
    assert body["reason"] == "external_ai_searches_per_day_exceeded", body
    assert body["limit_key"] == "external_ai_searches_per_day", body

    # 4. We capped searches, not the server. A non-search tool still answers.
    folders = _mcp_call(token, "list_folders", {"vault_id": vault_id})
    assert "result" in folders, (
        f"list_folders must not be charged to the search bucket; got {folders}"
    )
