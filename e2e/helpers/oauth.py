"""OAuth test helpers — shared setup/teardown for E2E tests that swap auth.

Provides functions to:
- Provision OAuth tokens via device flow for a NEW Clerk user
- Swap an Obsidian plugin instance to OAuth auth via CDP
- Restore original API key auth after test
- Wait for WebSocket channel to connect after auth change
"""

from __future__ import annotations

import asyncio
import json
import logging
import secrets
import time
from datetime import datetime

import requests

from helpers.device_flow import start_device_flow, poll_for_tokens

logger = logging.getLogger(__name__)

_P = "app.plugins.plugins['engram-vault-sync']"


async def provision_oauth_tokens(
    clerk_client, api_url: str, *, label: str = "test"
) -> tuple[str, dict]:
    """Create a Clerk user, run device flow, return (clerk_user_id, tokens).

    Each call creates a unique user with a timestamped email to avoid collisions.
    The label is used in the email prefix for log traceability.
    """
    ts = datetime.now().strftime("%Y%m%d%H%M%S%f")
    email = f"e2e-oauth-{label}-{ts}@example.com"
    password = secrets.token_urlsafe(32)

    clerk_user_id = clerk_client.create_user(email, password)
    logger.info("Created Clerk user for %s: %s (%s)", label, clerk_user_id, email)

    session_token = clerk_client.create_session_token(clerk_user_id)

    client_id = f"e2e-oauth-{label}-{ts}"
    flow = start_device_flow(api_url, client_id)

    resp = requests.post(
        f"{api_url}/auth/device/authorize",
        json={
            "user_code": flow["user_code"],
            "vault_id": "new",
            "vault_name": f"E2E OAuth {label}",
        },
        headers={"Authorization": f"Bearer {session_token}"},
        timeout=10,
    )
    assert resp.status_code == 200, f"Device authorize failed: {resp.status_code}"

    tokens = poll_for_tokens(api_url, flow["device_code"], timeout=30)
    assert "access_token" in tokens
    return clerk_user_id, tokens


async def provision_oauth_for_existing_user(
    clerk_client, api_url: str, clerk_user_id: str, *, label: str = "cross",
    api_key: str | None = None,
) -> dict:
    """Run device flow for an EXISTING Clerk user (no new user created).

    Returns tokens dict. Useful for cross-auth tests where both API key and
    OAuth need to target the same user. Uses the user's existing vault
    (looked up via session token) to avoid hitting vault limits.
    """
    ts = datetime.now().strftime("%Y%m%d%H%M%S%f")

    session_token = clerk_client.create_session_token(clerk_user_id)

    # Look up the user's existing vault to avoid creating a new one
    # (free tier has a vault limit — "new" would fail with 422)
    auth_header = f"Bearer {api_key}" if api_key else f"Bearer {session_token}"
    vaults_resp = requests.get(
        f"{api_url}/vaults",
        headers={"Authorization": auth_header},
        timeout=10,
    )
    assert vaults_resp.status_code == 200, f"Failed to list vaults: {vaults_resp.status_code}"
    vaults = vaults_resp.json().get("vaults", [])
    assert len(vaults) > 0, "Existing user has no vaults"
    vault_id = str(vaults[0]["id"])
    logger.info("Using existing vault %s for OAuth %s flow", vault_id, label)

    client_id = f"e2e-oauth-{label}-{ts}"
    flow = start_device_flow(api_url, client_id)

    resp = requests.post(
        f"{api_url}/auth/device/authorize",
        json={
            "user_code": flow["user_code"],
            "vault_id": vault_id,
        },
        headers={"Authorization": f"Bearer {session_token}"},
        timeout=10,
    )
    assert resp.status_code == 200, f"Device authorize failed: {resp.status_code}"

    tokens = poll_for_tokens(api_url, flow["device_code"], timeout=30)
    assert "access_token" in tokens
    return tokens


async def swap_to_oauth(cdp, tokens: dict) -> str:
    """Swap Obsidian plugin to OAuth auth via CDP.

    Returns original settings as JSON string for later restore.

    Auth/vault change rotates the sync fingerprint, which would normally
    close the gate and queue a SyncPreviewModal for the user to pick a
    new direction. Tests simulate that user choice by re-accepting the
    gate immediately — otherwise syncBlocked=true silently drops every
    WebSocket event (sync.ts handleStreamEvent short-circuit).
    """
    original = await cdp.evaluate(
        f"JSON.stringify({{apiKey: {_P}.settings.apiKey, "
        f"refreshToken: {_P}.settings.refreshToken, "
        f"vaultId: {_P}.settings.vaultId, "
        f"userEmail: {_P}.settings.userEmail, "
        f"authMethod: {_P}.settings.authMethod || 'apikey'}})"
    )

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
        plugin.setupNoteStream();
        if (typeof plugin.markSyncGateAccepted === 'function') {{
            await plugin.markSyncGateAccepted();
        }}
        return 'oauth configured';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin swapped to OAuth: %s", result)
    return original


async def restore_auth(cdp, original_settings_json: str) -> None:
    """Restore Obsidian plugin to its original auth settings via CDP.

    Like swap_to_oauth, this rotates the sync fingerprint back, so the
    gate must be re-accepted to keep the engine sync-active.
    """
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
        plugin.setupNoteStream();
        if (typeof plugin.markSyncGateAccepted === 'function') {{
            await plugin.markSyncGateAccepted();
        }}
        return 'auth restored';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin auth restored: %s", result)


async def wait_for_stream(cdp, timeout: float = 15) -> None:
    """Poll until WebSocket channel is connected after auth change."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await cdp.check_stream_connected():
            return
        await asyncio.sleep(1)
    raise TimeoutError(f"WebSocket channel not connected after {timeout}s")
