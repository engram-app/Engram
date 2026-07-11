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


def _assert_owns_vault(api_url: str, access_token: str, vault_id: str, *, label: str) -> None:
    """Fail fast if a freshly-minted OAuth vault_id isn't actually owned by
    this token's identity.

    Cheap GET /vaults check, done once at provisioning time. Without this,
    a cross-account vaultId (this identity's token, someone else's vault)
    joins `user:` fine but the `sync:` channel refuses it server-side with
    no client-visible error — nothing retries, and the caller just hangs
    on wait_for_stream's 120s timeout instead of failing loudly at the
    point the bad state was created. See
    docs/context/oauth-e2e-pairing-and-token-binding.md.
    """
    resp = requests.get(
        f"{api_url}/vaults",
        headers={"Authorization": f"Bearer {access_token}"},
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"[{label}] vault-ownership check: GET /vaults failed: "
        f"{resp.status_code} {resp.text[:300]}"
    )
    owned_ids = {str(v["id"]) for v in resp.json().get("vaults", [])}
    assert str(vault_id) in owned_ids, (
        f"[{label}] resolved vault_id={vault_id} is NOT owned by this identity's "
        f"token (owned vaults: {owned_ids or 'none'}) — cross-account vaultId "
        "would silently fail the sync: channel join and hang wait_for_stream "
        "for up to 120s instead of failing here"
    )


async def provision_oauth_tokens(
    clerk_client, api_url: str, *, label: str = "test"
) -> tuple[str, dict]:
    """Create a Clerk user, run device flow, return (clerk_user_id, tokens).

    Each call creates a unique user with a timestamped email to avoid collisions.
    The label is used in the email prefix for log traceability.
    """
    ts = datetime.now().strftime("%Y%m%d%H%M%S%f")
    email = f"e2e-oauth-{label}-{ts}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)

    clerk_user_id = clerk_client.create_user(email, password)
    logger.info("Created Clerk user for %s: %s (%s)", label, clerk_user_id, email)

    session_token = clerk_client.create_session_token(clerk_user_id)

    # Pre-complete onboarding so vault-scoped requests issued via the OAuth
    # access token returned below don't 403 onboarding_required. uses_obsidian
    # also short-circuits the vault step in Onboarding.next_step/5.
    prof_resp = requests.patch(
        f"{api_url}/onboarding/profile",
        json={"uses_obsidian": True, "tools": ["claude"]},
        headers={"Authorization": f"Bearer {session_token}"},
        timeout=10,
    )
    assert prof_resp.status_code in (200, 201), (
        f"Onboarding profile PATCH failed: {prof_resp.status_code} {prof_resp.text[:300]}"
    )

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
    _assert_owns_vault(api_url, tokens["access_token"], tokens["vault_id"], label=label)
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
    _assert_owns_vault(api_url, tokens["access_token"], vault_id, label=label)
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

    # IMPORTANT: do NOT blank apiKey. createAuthProvider() at main.ts:541
    # checks refreshToken FIRST and returns OAuthAuth regardless of apiKey
    # state, so setting refreshToken is sufficient to swap. Blanking apiKey
    # used to corrupt disk state via saveSettings() — if restore_auth then
    # threw mid-execution, the apiKey was lost forever and every subsequent
    # swap_to_oauth on the same worker captured the empty apiKey as
    # "original", cascading 401s for the rest of the suite.
    js = f"""
    (async function() {{
        const plugin = {_P};
        // Clear vault-scoped state from whatever identity is currently
        // loaded BEFORE adopting the new one. A stale settings.vaultId (or
        // an accessToken cached+bound to a prior account's vault via
        // accessTokenVaultId) surviving into this swap can silently join
        // the wrong sync: topic — the backend refuses that join
        // server-side with no client-visible error, and nothing retries
        // (docs/context/oauth-e2e-pairing-and-token-binding.md).
        plugin.settings.vaultId = null;
        plugin.settings.accessToken = undefined;
        plugin.settings.accessTokenExpiresAt = undefined;
        plugin.settings.accessTokenVaultId = undefined;
        // Re-resolve for the new identity from freshly-minted, server-verified tokens.
        plugin.settings.refreshToken = {refresh_token};
        plugin.settings.vaultId = {vault_id};
        plugin.settings.userEmail = {user_email};
        plugin.settings.authMethod = 'oauth';
        // Wire the new auth provider onto plugin.api BEFORE saveSettings(): it
        // rebuilds the note channel (setupNoteStream -> connectChannel), which
        // freezes the channel's topic userId from api.getMe() at construction.
        // With the OLD provider still active, getMe() resolves the old user and
        // the channel is minted crdt:<oldUser>:<newVault> while the socket auths
        // as the new user -> join rejected "unauthorized". Mirrors the prod fix
        // in main.ts saveOAuthTokens (Engram-obsidian#229).
        plugin.authProvider = plugin.createAuthProvider();
        if (plugin.authProvider) {{
            plugin.api.setAuthProvider(plugin.authProvider);
            if (plugin.noteStream) {{
                plugin.noteStream.setAuthProvider(plugin.authProvider);
            }}
        }}
        await plugin.saveSettings();
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


async def restore_auth(cdp, original_settings_json: str, verify_timeout: float = 30) -> None:
    """Restore Obsidian plugin to its original auth settings via CDP.

    Like swap_to_oauth, this rotates the sync fingerprint back, so the
    gate must be re-accepted to keep the engine sync-active.

    Verifies the restore rebound the channel (stream reconnects as the restored
    identity) and raises TimeoutError if not — a cross-bind must fail here, not
    silently poison every later test that reuses this session-scoped device.
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
        // Same staleness concern as swap_to_oauth: drop any accessToken
        // cached+bound (via accessTokenVaultId) to the OAuth vault we're
        // walking away from before restoring the original identity.
        plugin.settings.accessToken = undefined;
        plugin.settings.accessTokenExpiresAt = undefined;
        plugin.settings.accessTokenVaultId = undefined;
        plugin.settings.apiKey = {api_key};
        plugin.settings.refreshToken = {refresh_token};
        plugin.settings.vaultId = {vault_id};
        plugin.settings.userEmail = {user_email};
        plugin.settings.authMethod = {auth_method};
        // Provider before saveSettings — same ordering invariant as swap_to_oauth
        // (see the comment there): the channel-rebuilding saveSettings() must see
        // the restored provider so getMe() freezes the RESTORED user's id into the
        // topic, matching the restored token.
        plugin.authProvider = plugin.createAuthProvider();
        if (plugin.authProvider) {{
            plugin.api.setAuthProvider(plugin.authProvider);
            if (plugin.noteStream) {{
                plugin.noteStream.setAuthProvider(plugin.authProvider);
            }}
        }}
        await plugin.saveSettings();
        plugin.setupNoteStream();
        if (typeof plugin.markSyncGateAccepted === 'function') {{
            await plugin.markSyncGateAccepted();
        }}
        return 'auth restored';
    }})()
    """
    result = await cdp.evaluate(js, await_promise=True)
    logger.info("Plugin auth restored: %s", result)

    # VERIFY the restore actually rebound: the channel must reconnect as the
    # restored identity. A silent cross-bind (vaultId restored but token/userId
    # not, or vice versa) leaves the session-scoped device joining the wrong
    # `crdt:` topic — the backend rejects it "unauthorized" with no client error,
    # and (before this check) nothing caught it, so every LATER test that reuses
    # this device failed with a misleading "Stream not connected" (test_84/85).
    # Fail loudly HERE, at the restore site, instead of 40 tests downstream. The
    # timeout message carries the channel diagnostic (crdtJoinFailedReason etc).
    await cdp.wait_for_stream_connected(timeout=verify_timeout)


async def wait_for_stream(cdp, timeout: float = 60) -> None:
    """Poll until WebSocket channel is connected after auth change.

    60s (was 30s, which was 15s before #643): under full-suite e2e-clerk load
    (2-worker xdist + Clerk latency + a SECOND Obsidian instance booting) the
    OAuth connect chain — token refresh + getMe (2s/4s retry backoff) + WS
    phx_join — intermittently exceeded 30s (test_47/test_48). reruns=0
    (test-confidence-wave) exposed this: reruns had been silently doubling
    the effective wait. This is a budget bump only — plugin-obsidian#186
    diagnoses a SEPARATE post-connect delivery race (never-seen CRDT note
    lost between `crdt:` join and the `crdt_doc_ready` announce) that this
    gate does not touch; that fix is tracked there, not here.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await cdp.check_stream_connected():
            return
        await asyncio.sleep(1)
    raise TimeoutError(f"WebSocket channel not connected after {timeout}s")
