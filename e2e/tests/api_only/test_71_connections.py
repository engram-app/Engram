"""E2E test for /api/connections page + tier-gated connection caps.

API-only — runs during the Obsidian boot gap. Mirrors what the plugin
does at the wire level (DCR with kind=obsidian → consent → token) so
we can validate the end-to-end flow without the headless Obsidian
dependency.

When the plugin ships kind=obsidian in DCR (Phase 8), test_44 will
naturally cover the obsidian path through the real plugin code; this
test stays as the API-contract guardrail.

Requires:
- E2E_CLERK_SECRET_KEY env var (for Clerk session-token auth on
  /api/connections + /api/oauth/authorize/consent)
- CI stack with Clerk env vars
"""
from __future__ import annotations

import base64
import hashlib
import logging
import os
import secrets
import subprocess
from datetime import datetime
from urllib.parse import parse_qs, urlparse

import pytest
import requests

from helpers.billing import grant_test_plan

logger = logging.getLogger(__name__)

# API_URL is e.g. "http://localhost:8100/api"
API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
# OAuth endpoints live at /oauth/*, not /api/oauth/*, so strip the /api suffix
OAUTH_BASE = API_URL[: -len("/api")] if API_URL.endswith("/api") else API_URL.rsplit("/api", 1)[0]

CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping connections tests",
)

# ── PKCE verifier/challenge pair ─────────────────────────────────────────────
# Computed at module load: SHA-256(verifier) base64url-encoded = challenge.
# Reused across tests since each test has its own client + code — PKCE only
# guards the single exchange round-trip.
_PKCE_VERIFIER = secrets.token_urlsafe(32)
_PKCE_CHALLENGE = (
    base64.urlsafe_b64encode(hashlib.sha256(_PKCE_VERIFIER.encode()).digest())
    .rstrip(b"=")
    .decode()
)


# ── Helpers ───────────────────────────────────────────────────────────────────


def _ts() -> str:
    """Compact timestamp for unique identifiers."""
    return datetime.now().strftime("%Y%m%d%H%M%S%f")


def register_client(software_id: str, client_name: str, kind: str | None = None) -> dict:
    """POST /oauth/register — RFC 7591 DCR. Returns the registration response dict."""
    body: dict = {
        "client_name": client_name,
        "software_id": software_id,
        "redirect_uris": ["http://127.0.0.1:51234/cb"],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none",
    }
    if kind is not None:
        body["kind"] = kind
    resp = requests.post(f"{OAUTH_BASE}/oauth/register", json=body, timeout=10)
    resp.raise_for_status()
    return resp.json()


def consent(jwt_token: str, client_id: str, *, vault_choice: str = "vault:*") -> requests.Response:
    """POST /api/oauth/authorize/consent — returns the raw Response.

    Success (200): JSON body `{redirect_uri: "...?code=..."}`.
    Cap hit (402): JSON body with error details.
    """
    payload = {
        "client_id": client_id,
        "state": secrets.token_urlsafe(8),
        "code_challenge": _PKCE_CHALLENGE,
        "code_challenge_method": "S256",
        "redirect_uri": "http://127.0.0.1:51234/cb",
        "scope": "mcp",
        "response_type": "code",
        "vault_choice": vault_choice,
    }
    return requests.post(
        f"{API_URL}/oauth/authorize/consent",
        json=payload,
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )


def exchange_code(client_id: str, code: str) -> dict:
    """POST /oauth/token — exchange auth code for access + refresh tokens."""
    resp = requests.post(
        f"{OAUTH_BASE}/oauth/token",
        json={
            "grant_type": "authorization_code",
            "code": code,
            "client_id": client_id,
            "code_verifier": _PKCE_VERIFIER,
            "redirect_uri": "http://127.0.0.1:51234/cb",
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def list_connections(jwt_token: str) -> list[dict]:
    """GET /api/connections."""
    resp = requests.get(
        f"{API_URL}/connections",
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def revoke_oauth(jwt_token: str, client_id: str) -> int:
    """DELETE /api/connections/oauth/:client_id. Returns HTTP status code."""
    resp = requests.delete(
        f"{API_URL}/connections/oauth/{client_id}",
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )
    return resp.status_code


def mint_pat(jwt_token: str, name: str) -> requests.Response:
    """POST /api/connections/pat. Returns raw Response — 201 on paid, 402 on Free."""
    return requests.post(
        f"{API_URL}/connections/pat",
        json={"name": name},
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )


def _extract_code(redirect_uri: str) -> str:
    """Parse the auth code out of a redirect URI query string."""
    return parse_qs(urlparse(redirect_uri).query)["code"][0]


def _make_clerk_user(clerk_client) -> tuple[str, str, str]:
    """Create a fresh Clerk user + Engram DB row. Returns (clerk_user_id, jwt_token, email).

    The user is NOT granted api_write/rps overrides — they keep Free-tier
    defaults. Callers that need paid-tier behaviour must call
    `grant_test_plan(email)` themselves.
    """
    ts = _ts()
    email = f"e2e-conn-{ts}@example.com"
    password = secrets.token_urlsafe(32)

    clerk_user_id = clerk_client.create_user(email, password)

    # POST /api-keys via Clerk JWT to provision the user row in the Engram DB.
    # Without this the user won't exist yet and /api/connections returns 401.
    initial_jwt = clerk_client.create_session_token(clerk_user_id)
    resp = requests.post(
        f"{API_URL}/api-keys",
        json={"name": "e2e-bootstrap-key"},
        headers={"Authorization": f"Bearer {initial_jwt}"},
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"User DB provisioning failed: {resp.status_code} {resp.text}"
    )

    jwt_token = clerk_client.create_session_token(clerk_user_id)
    return clerk_user_id, jwt_token, email


def _set_mcp_cap(email: str, cap: int) -> None:
    """Insert/update user_limit_overrides to set mcp_connections_cap via docker exec SQL."""
    sql = (
        f"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES ((SELECT id FROM users WHERE email = '{email}'), "
        f"'mcp_connections_cap', '{{\"v\": {cap}}}'::jsonb, 'e2e-test', 'e2e') "
        f"ON CONFLICT (user_id, key) DO UPDATE "
        f"SET value = EXCLUDED.value, set_at = NOW()"
    )
    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"_set_mcp_cap failed: {result.stderr.strip()}")


def _set_api_write(email: str, enabled: bool) -> None:
    """Set api_write_enabled override for a user."""
    val = "true" if enabled else "false"
    sql = (
        f"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES ((SELECT id FROM users WHERE email = '{email}'), "
        f"'api_write_enabled', '{{\"v\": {val}}}'::jsonb, 'e2e-test', 'e2e') "
        f"ON CONFLICT (user_id, key) DO UPDATE "
        f"SET value = EXCLUDED.value, set_at = NOW()"
    )
    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"_set_api_write failed: {result.stderr.strip()}")


# ── Tests ─────────────────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_connections_empty_for_fresh_user(clerk_client):
    """A freshly-created user with no OAuth grants or PATs sees []."""
    clerk_user_id, jwt, _email = _make_clerk_user(clerk_client)
    try:
        rows = list_connections(jwt)
        # May include the bootstrap PAT created during provisioning but no OAuth rows
        oauth_rows = [r for r in rows if r["kind"] != "pat"]
        assert oauth_rows == [], f"expected no OAuth connections, got {oauth_rows}"
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_dcr_kind_obsidian_appears_with_verified_logo(clerk_client):
    """DCR with kind=obsidian + software_id=engram-vault-sync → connection
    shows up in /api/connections with kind='obsidian', verified=true,
    display_name from LogoAllowlist."""
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    grant_test_plan(email)
    try:
        client = register_client(
            software_id="engram-vault-sync",
            client_name="Engram Vault Sync",
            kind="obsidian",
        )
        client_id = client["client_id"]

        resp = consent(jwt, client_id)
        assert resp.status_code == 200, (
            f"consent failed: {resp.status_code} {resp.text}"
        )
        code = _extract_code(resp.json()["redirect_uri"])
        exchange_code(client_id, code)

        rows = list_connections(jwt)
        obsidian = [r for r in rows if r["kind"] == "obsidian"]
        assert len(obsidian) == 1, f"expected 1 obsidian connection, got {len(obsidian)}"
        assert obsidian[0]["client_id"] == client_id
        assert obsidian[0]["verified"] is True, "engram-vault-sync should be verified"
        assert obsidian[0]["name"] == "Obsidian Vault Sync", (
            f"unexpected display name: {obsidian[0]['name']!r}"
        )
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_unknown_software_id_shows_unverified(clerk_client):
    """DCR with kind=mcp + unknown software_id → verified=False in /api/connections."""
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    grant_test_plan(email)
    try:
        software_id = f"unknown-client-{secrets.token_hex(4)}"
        client = register_client(
            software_id=software_id,
            client_name="Unknown Tool",
            kind="mcp",
        )
        client_id = client["client_id"]

        resp = consent(jwt, client_id)
        assert resp.status_code == 200, (
            f"consent failed: {resp.status_code} {resp.text}"
        )
        code = _extract_code(resp.json()["redirect_uri"])
        exchange_code(client_id, code)

        rows = list_connections(jwt)
        match = next((r for r in rows if r["client_id"] == client_id), None)
        assert match is not None, "connection not found in list"
        assert match["verified"] is False, (
            f"unknown software_id should be unverified, got verified={match['verified']}"
        )
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_revoke_oauth_removes_from_list(clerk_client):
    """DELETE /api/connections/oauth/:client_id removes the connection.
    Second revoke is also 204 (idempotent — history record exists)."""
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    grant_test_plan(email)
    try:
        client = register_client(
            software_id="anthropic-claude-desktop",
            client_name="Claude Desktop",
            kind="mcp",
        )
        cid = client["client_id"]

        resp = consent(jwt, cid)
        assert resp.status_code == 200, (
            f"consent failed: {resp.status_code} {resp.text}"
        )
        code = _extract_code(resp.json()["redirect_uri"])
        exchange_code(cid, code)

        # Confirm present
        assert any(r["client_id"] == cid for r in list_connections(jwt)), (
            "connection not found after consent+exchange"
        )

        # Revoke
        status = revoke_oauth(jwt, cid)
        assert status == 204, f"expected 204 on revoke, got {status}"

        # Gone from list
        assert not any(r["client_id"] == cid for r in list_connections(jwt)), (
            "connection still listed after revoke"
        )

        # Second revoke is idempotent (history row exists → :ok → 204)
        status2 = revoke_oauth(jwt, cid)
        assert status2 == 204, (
            f"expected 204 on second (idempotent) revoke, got {status2}"
        )
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_free_tier_cap_blocks_second_mcp_consent(clerk_client):
    """Free-tier user (mcp_connections_cap=1): first MCP consent succeeds,
    second MCP consent returns 402 connection_cap_reached."""
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    # Set rps cap to allow API calls but keep api_write_enabled false and
    # set mcp_connections_cap=1 (the Free default, verified explicitly)
    _set_mcp_cap(email, 1)
    # Lift rps so the consent endpoint itself isn't 429'd
    subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-c",
            (
                f"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
                f"VALUES ((SELECT id FROM users WHERE email = '{email}'), "
                f"'api_rps_cap', '{{\"v\": 1000}}'::jsonb, 'e2e-test', 'e2e') "
                f"ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, set_at = NOW()"
            ),
        ],
        capture_output=True, text=True, timeout=10,
    )
    try:
        # First MCP connection succeeds
        c1 = register_client(
            software_id="anthropic-claude-desktop",
            client_name="Claude Desktop",
            kind="mcp",
        )
        resp1 = consent(jwt, c1["client_id"])
        assert resp1.status_code == 200, (
            f"first MCP consent should succeed, got {resp1.status_code}: {resp1.text}"
        )
        code1 = _extract_code(resp1.json()["redirect_uri"])
        exchange_code(c1["client_id"], code1)

        # Second MCP consent (different client) → 402
        c2 = register_client(
            software_id="cursor.sh",
            client_name="Cursor",
            kind="mcp",
        )
        resp2 = consent(jwt, c2["client_id"])
        assert resp2.status_code == 402, (
            f"second MCP consent should be 402, got {resp2.status_code}: {resp2.text}"
        )
        body = resp2.json()
        assert body["error"] == "connection_cap_reached"
        assert body["kind"] == "mcp"
        assert body["current"] == 1
        assert body["limit"] == 1
        assert body["upgrade_url"] == "/settings/billing"
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_free_tier_pat_minting_blocked(clerk_client):
    """Free user POST /api/connections/pat → 402 pat_disabled_on_free.

    api_write_enabled defaults to false on Free; this plug fires before
    any PAT-name validation.
    """
    clerk_user_id, jwt, _email = _make_clerk_user(clerk_client)
    # Do NOT call grant_test_plan — keep api_write_enabled=false (Free default)
    try:
        resp = mint_pat(jwt, "ci-bot")
        assert resp.status_code == 402, (
            f"expected 402 for Free user PAT mint, got {resp.status_code}: {resp.text}"
        )
        body = resp.json()
        assert body["error"] == "pat_disabled_on_free"
        assert body["upgrade_url"] == "/settings/billing"
    finally:
        clerk_client.delete_user(clerk_user_id)
