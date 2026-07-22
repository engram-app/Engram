"""Test 47: OAuth-authenticated client receives WebSocket broadcasts in real-time.

Regression test for the setupNoteStream fix — previously, WebSocket channel
setup only checked for apiKey (null for OAuth users), so OAuth clients never
joined the channel and missed all real-time broadcasts.

After the fix, setupNoteStream checks for refreshToken too, and the channel
topic is always sync:{user_id}:{vault_id}.

Requires E2E_CLERK_SECRET_KEY env var for device flow provisioning.
"""

from __future__ import annotations

import logging
import os
import time
from urllib.parse import quote

import pytest
import requests

from helpers.oauth import provision_oauth_tokens, swap_to_oauth, restore_auth, wait_for_stream
from helpers.vault import read_note, wait_for_content, wait_for_file, wait_for_file_gone
from helpers.latency import DELIVERY_TIMEOUT

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping OAuth WebSocket tests",
)

# WS round-trip budget under e2e-clerk load (2-worker xdist + Clerk-auth
# latency). 10s flaked repeatedly (#643). Tightened 30s → 15s: this is a
# live-sync latency property — a 30s budget would mask a real broadcast
# regression. If 15s flakes, profile the xdist contention; do not re-widen.
RT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound; latency is recorded, not asserted


def _log_latency(label: str, t0: float) -> float:
    elapsed = time.monotonic() - t0
    logger.info("LATENCY [%s]: %.3fs", label, elapsed)
    return elapsed


@pytest.mark.asyncio
async def test_oauth_client_receives_api_create(vault_a, cdp_a, clerk_client, _oauth_ws_warm):
    """OAuth-authenticated plugin receives real-time broadcast when API creates a note.

    This is the core regression test: before the fix, OAuth clients never joined
    the WebSocket channel because setupNoteStream only checked for apiKey.
    """
    clerk_user_id, tokens = await provision_oauth_tokens(clerk_client, API_URL, label="ws")
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        connected = await cdp_a.check_stream_connected()
        assert connected, "OAuth client's WebSocket channel is not connected"

        path = "E2E/OAuthWSCreate.md"
        content = "# OAuth WS Create\nCreated via API, should arrive via WebSocket"
        headers = {
            "Authorization": f"Bearer {tokens['access_token']}",
            "X-Vault-ID": str(tokens["vault_id"]),
        }
        resp = requests.post(
            f"{API_URL}/notes",
            json={"path": path, "content": content, "mtime": time.time()},
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"API create failed: {resp.status_code}"

        t0 = time.monotonic()
        a_content = wait_for_file(vault_a, path, timeout=RT_TIMEOUT)
        _log_latency("oauth_api_create", t0)

        assert "should arrive via WebSocket" in a_content

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_oauth_client_receives_api_update(vault_a, cdp_a, clerk_client, _oauth_ws_warm):
    """OAuth client receives updated content via WebSocket when API upserts a note."""
    clerk_user_id, tokens = await provision_oauth_tokens(clerk_client, API_URL, label="ws")
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        path = "E2E/OAuthWSUpdate.md"
        headers = {
            "Authorization": f"Bearer {tokens['access_token']}",
            "X-Vault-ID": str(tokens["vault_id"]),
        }

        # Create initial version
        resp = requests.post(
            f"{API_URL}/notes",
            json={"path": path, "content": "# V1\nInitial", "mtime": time.time()},
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"Initial create failed: {resp.status_code}"
        wait_for_file(vault_a, path, timeout=RT_TIMEOUT)

        # Update via API
        t0 = time.monotonic()
        resp = requests.post(
            f"{API_URL}/notes",
            json={"path": path, "content": "# V2\nUpdated via API", "mtime": time.time()},
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"Update failed: {resp.status_code}"
        wait_for_content(vault_a, path, "Updated via API", timeout=RT_TIMEOUT)
        _log_latency("oauth_api_update", t0)

        assert "Updated via API" in read_note(vault_a, path)

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_oauth_client_receives_api_delete(vault_a, cdp_a, clerk_client, _oauth_ws_warm):
    """OAuth client removes file from vault when API deletes a note via WebSocket."""
    clerk_user_id, tokens = await provision_oauth_tokens(clerk_client, API_URL, label="ws")
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        path = "E2E/OAuthWSDelete.md"
        headers = {
            "Authorization": f"Bearer {tokens['access_token']}",
            "X-Vault-ID": str(tokens["vault_id"]),
        }

        # Create and wait for arrival
        resp = requests.post(
            f"{API_URL}/notes",
            json={"path": path, "content": "# Delete Me", "mtime": time.time()},
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"Create failed: {resp.status_code}"
        wait_for_file(vault_a, path, timeout=RT_TIMEOUT)

        # Delete via API
        t0 = time.monotonic()
        resp = requests.delete(
            f"{API_URL}/notes/{quote(path, safe='')}",
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 204), f"Delete failed: {resp.status_code}"

        wait_for_file_gone(vault_a, path, timeout=RT_TIMEOUT)
        _log_latency("oauth_api_delete", t0)

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)
        clerk_client.delete_user(clerk_user_id)
