"""Test 44: Full OAuth device flow — create user, authorize, sync with OAuth tokens.

Uses Clerk Backend API to create a test user and session (no browser needed).
Then exercises the device flow: start → authorize → exchange → sync.

Requires:
- E2E_CLERK_SECRET_KEY env var (Clerk Backend API key)
- CI stack with Clerk env vars configured

Skipped automatically if E2E_CLERK_SECRET_KEY is not set.
"""

from __future__ import annotations

import json
import logging
import os
import secrets
from datetime import datetime
from urllib.parse import quote

import pytest
import requests

from helpers.device_flow import start_device_flow, poll_for_tokens
from helpers.vault import write_note

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")

CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping device flow tests",
)

# CDP plugin path shorthand
_P = "app.plugins.plugins['engram-vault-sync']"


@pytest.fixture
def test_email():
    ts = datetime.now().strftime("%Y%m%d%H%M%S")
    return f"e2e-clerk-{ts}@example.com"


@pytest.fixture
def test_password():
    return secrets.token_urlsafe(32)


@pytest.mark.asyncio
async def test_full_device_flow(
    vault_a, cdp_a, api_sync, sync_user, clerk_client, test_email, test_password
):
    """Full journey: create user → device flow → authorize → sync with OAuth tokens."""

    # ── 1. Create Clerk user via Backend API ──────────────────────
    clerk_user_id = clerk_client.create_user(test_email, test_password)
    logger.info("Created Clerk user: %s (%s)", clerk_user_id, test_email)

    try:
        # ── 2. Get Clerk session token for the new user ───────────
        session_token = clerk_client.create_session_token(clerk_user_id)
        logger.info("Got Clerk session token for %s", test_email)

        # ── 3. Start device flow ──────────────────────────────────
        ts = datetime.now().strftime("%Y%m%d%H%M%S")
        client_id = f"e2e-device-{ts}"
        flow = start_device_flow(API_URL, client_id)
        device_code = flow["device_code"]
        user_code = flow["user_code"]
        logger.info("Device flow started: user_code=%s", user_code)

        # ── 4. Authorize device flow using Clerk session token ────
        # This replaces the entire browser flow. The authorize endpoint
        # accepts any valid auth token — we use the Clerk JWT directly.
        resp = requests.post(
            f"{API_URL}/auth/device/authorize",
            json={"user_code": user_code, "vault_id": "new", "vault_name": "E2E Test Vault"},
            headers={"Authorization": f"Bearer {session_token}"},
            timeout=10,
        )
        assert resp.status_code == 200, (
            f"Device authorize failed: {resp.status_code} {resp.text}"
        )
        logger.info("Device flow authorized via Backend API")

        # ── 5. Exchange device code for tokens ────────────────────
        tokens = poll_for_tokens(API_URL, device_code, timeout=30)
        assert "access_token" in tokens, "No access_token in exchange response"
        assert tokens["refresh_token"].startswith("engram_rt_"), (
            f"Refresh token missing prefix: {tokens['refresh_token'][:20]}"
        )
        assert "vault_id" in tokens
        assert tokens.get("user_email") == test_email
        logger.info("Tokens received: vault_id=%s", tokens["vault_id"])

        # ── 6. Reconfigure Obsidian A to use OAuth ────────────────
        original_settings = await cdp_a.evaluate(
            f"JSON.stringify({{apiKey: {_P}.settings.apiKey, "
            f"refreshToken: {_P}.settings.refreshToken, "
            f"vaultId: {_P}.settings.vaultId, "
            f"userEmail: {_P}.settings.userEmail, "
            f"authMethod: {_P}.settings.authMethod || 'apikey'}})"
        )

        try:
            await _swap_to_oauth(cdp_a, tokens)

            # Write a test note and sync
            path = "E2E/OAuthDeviceFlowTest.md"
            content = "# OAuth Device Flow E2E\nSynced with OAuth tokens from device flow test."
            write_note(vault_a, path, content)

            # Trigger sync
            result = await cdp_a.trigger_full_sync()
            logger.info("Sync result: %s", result)
            assert result.get("pushed", 0) >= 1, f"Expected push, got: {result}"

            # Verify note reached server using OAuth access token
            resp = requests.get(
                f"{API_URL}/notes/{quote(path, safe='')}",
                headers={
                    "Authorization": f"Bearer {tokens['access_token']}",
                    "X-Vault-ID": str(tokens["vault_id"]),
                },
                timeout=10,
            )
            assert resp.status_code == 200, f"Server GET returned {resp.status_code}"
            assert "OAuth Device Flow E2E" in resp.json().get("content", "")

        finally:
            # ── 7. Restore original API key auth ──────────────────
            await _restore_auth(cdp_a, original_settings)

    finally:
        # ── 8. Cleanup: delete Clerk user ─────────────────────────
        clerk_client.delete_user(clerk_user_id)
        logger.info("Clerk user cleaned up: %s", test_email)


# ── Private helpers ───────────────────────────────────────────────


async def _swap_to_oauth(cdp, tokens: dict) -> None:
    """Reconfigure Obsidian plugin to use OAuth auth via CDP.

    Re-accepts the sync gate after the swap because the fingerprint
    rotates with the auth/vault change — without the accept,
    syncBlocked stays true and the post-swap fullSync silently no-ops.
    """
    refresh_token = json.dumps(tokens["refresh_token"])
    vault_id = json.dumps(str(tokens["vault_id"]))
    user_email = json.dumps(tokens.get("user_email", ""))

    js = f"""
    (async function() {{
        const plugin = {_P};
        plugin.settings.apiKey = '';
        plugin.settings.refreshToken = {refresh_token};
        plugin.settings.vaultId = {vault_id};
        plugin.settings.userEmail = {user_email};
        plugin.settings.authMethod = 'oauth';
        await plugin.saveSettings();
        plugin.authProvider = plugin.createAuthProvider();
        if (plugin.authProvider) {{
            plugin.api.setAuthProvider(plugin.authProvider);
            if (plugin.noteStream) {{
                plugin.noteStream.setAuthProvider(plugin.authProvider);
            }}
        }}
        await plugin.markSyncGateAccepted();
        return 'oauth configured';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin reconfigured to OAuth: %s", result)
    await cdp.wait_for_plugin_ready(timeout=15)


async def _restore_auth(cdp, original_settings_json: str) -> None:
    """Restore Obsidian plugin to original auth settings via CDP."""
    settings = json.loads(original_settings_json)
    api_key = json.dumps(settings.get("apiKey", ""))
    refresh_token = json.dumps(settings.get("refreshToken", ""))
    vault_id = json.dumps(settings.get("vaultId", ""))
    user_email = json.dumps(settings.get("userEmail", ""))
    auth_method = json.dumps(settings.get("authMethod", "apikey"))

    js = f"""
    (async function() {{
        const plugin = {_P};
        plugin.settings.apiKey = {api_key};
        plugin.settings.refreshToken = {refresh_token};
        plugin.settings.vaultId = {vault_id};
        plugin.settings.userEmail = {user_email};
        plugin.settings.authMethod = {auth_method};
        await plugin.saveSettings();
        plugin.authProvider = plugin.createAuthProvider();
        if (plugin.authProvider) {{
            plugin.api.setAuthProvider(plugin.authProvider);
            if (plugin.noteStream) {{
                plugin.noteStream.setAuthProvider(plugin.authProvider);
            }}
        }}
        await plugin.markSyncGateAccepted();
        return 'auth restored';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin auth restored: %s", result)
    await cdp.wait_for_plugin_ready(timeout=15)
