"""Test 48: OAuth client WebSocket reconnect → catch-up pull.

When an OAuth-authenticated client's WebSocket channel drops, changes made
while disconnected should be delivered via catch-up pull on reconnect.

This combines the reconnect pattern (test_23) with OAuth authentication to
ensure token refresh and channel re-join work correctly after disconnection.

Requires E2E_CLERK_SECRET_KEY env var for device flow provisioning.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time

import pytest
import requests

from helpers.oauth import provision_oauth_tokens, swap_to_oauth, restore_auth, wait_for_stream
from helpers.vault import read_note, wait_for_content, wait_for_file

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping OAuth reconnect tests",
)

# Reconnect + catch-up round-trip budget under e2e-clerk load. 15s flaked
# once (#643) but 30s masks real catch-up latency regressions. Tightened
# back to 15s; if it flakes, profile the xdist contention — do not re-widen.
RT_TIMEOUT = 15


def _log_latency(label: str, t0: float) -> float:
    elapsed = time.monotonic() - t0
    logger.info("LATENCY [%s]: %.3fs", label, elapsed)
    return elapsed


@pytest.mark.asyncio
async def test_oauth_reconnect_catches_up(vault_a, cdp_a, clerk_client):
    """OAuth channel drops, API creates note, channel reconnects, client gets note.

    Proves that OAuth token re-auth + channel re-join works after disconnect,
    and the catch-up pull fetches missed changes.
    """
    clerk_user_id, tokens = await provision_oauth_tokens(clerk_client, API_URL, label="rc")
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        assert await cdp_a.check_stream_connected(), "OAuth channel should be connected"

        # Disconnect the WebSocket channel
        await cdp_a.disconnect_stream()
        await asyncio.sleep(0.5)
        assert not await cdp_a.check_stream_connected(), "Channel should be disconnected"

        # Create a note via API while channel is down
        path = "E2E/OAuthReconnect.md"
        content = "# OAuth Reconnect\nCreated while OAuth client was disconnected"
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
        assert resp.status_code in (200, 201), f"Create failed: {resp.status_code}"

        # Reconnect — should trigger catch-up pull
        t0 = time.monotonic()
        await cdp_a.reconnect_stream()

        a_content = wait_for_file(vault_a, path, timeout=RT_TIMEOUT)
        _log_latency("oauth_reconnect_catchup", t0)

        assert "Created while OAuth client was disconnected" in a_content

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_oauth_reconnect_receives_update(vault_a, cdp_a, clerk_client):
    """OAuth channel drops, API updates existing note, reconnect delivers update.

    Edge case: file already exists locally, content changes while disconnected.
    """
    clerk_user_id, tokens = await provision_oauth_tokens(clerk_client, API_URL, label="rc")
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        path = "E2E/OAuthReconnectUpdate.md"
        headers = {
            "Authorization": f"Bearer {tokens['access_token']}",
            "X-Vault-ID": str(tokens["vault_id"]),
        }

        # Create initial note and wait for arrival
        resp = requests.post(
            f"{API_URL}/notes",
            json={"path": path, "content": "# V1\nOriginal content", "mtime": time.time()},
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"Initial create failed: {resp.status_code}"
        wait_for_file(vault_a, path, timeout=RT_TIMEOUT)

        # Disconnect
        await cdp_a.disconnect_stream()
        await asyncio.sleep(0.5)

        # Update while disconnected
        resp = requests.post(
            f"{API_URL}/notes",
            json={"path": path, "content": "# V2\nUpdated while disconnected", "mtime": time.time()},
            headers=headers,
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"Update failed: {resp.status_code}"

        # Reconnect — catch-up should deliver update
        t0 = time.monotonic()
        await cdp_a.reconnect_stream()

        wait_for_content(vault_a, path, "Updated while disconnected", timeout=RT_TIMEOUT)
        _log_latency("oauth_reconnect_update", t0)

        assert "Updated while disconnected" in read_note(vault_a, path)

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)
        clerk_client.delete_user(clerk_user_id)
