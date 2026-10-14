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

from helpers.billing import grant_test_plan, grant_vault_headroom

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


def _pending_body(resp) -> bool:
    """RFC 8628 puts the pending discriminator in the body, not the status."""
    try:
        return resp.json().get("error") == "authorization_pending"
    except ValueError:
        return False


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


def consent(
    jwt_token: str,
    client_id: str,
    *,
    vault_choice: str = "vault:*",
    vault_ids: list[str] | None = None,
) -> requests.Response:
    """POST /api/oauth/authorize/consent — returns the raw Response.

    Success (200): JSON body `{redirect_uri: "...?code=..."}`.
    Cap hit (402): JSON body with error details.

    `vault_ids` is the multi-vault shape the consent screen sends today;
    `vault_choice` is its single-vault predecessor, still accepted for one
    release and still the default here so the back-compat clause keeps its
    coverage. When `vault_ids` is given it is sent ALONE — the server prefers
    it when both are present, so sending both would exercise the precedence
    rule rather than the scoping.
    """
    payload = {
        "client_id": client_id,
        "state": secrets.token_urlsafe(8),
        "code_challenge": _PKCE_CHALLENGE,
        "code_challenge_method": "S256",
        "redirect_uri": "http://127.0.0.1:51234/cb",
        "scope": "mcp",
        "response_type": "code",
    }
    if vault_ids is None:
        payload["vault_choice"] = vault_choice
    else:
        payload["vault_ids"] = vault_ids
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
    email = f"e2e-conn-{ts}+clerk_test@example.com"
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

    # Complete the FTUX questionnaire, mirroring helpers/clerk_auth.py and
    # helpers/oauth.py. Provisioning the DB row is not the same as onboarding:
    # `POST /api/auth/device/authorize` is gated on the same verdict the
    # sync channels use (`Engram.Onboarding.gate/1`), so a user who never
    # answered `tools` gets 403 onboarding_required missing=["profile"].
    # A real user answers this on the `tools` step, which precedes the vault
    # step where they link the plugin — so onboarding here is what makes the
    # fixture resemble a real account, not a workaround.
    prof = requests.patch(
        f"{API_URL}/onboarding/profile",
        json={"uses_obsidian": True, "tools": ["claude"]},
        headers={"Authorization": f"Bearer {initial_jwt}"},
        timeout=10,
    )
    assert prof.status_code in (200, 201), (
        f"Onboarding profile PATCH failed: {prof.status_code} {prof.text}"
    )

    jwt_token = clerk_client.create_session_token(clerk_user_id)
    return clerk_user_id, jwt_token, email


def device_start(
    client_id: str = "e2e-plugin",
    vault_name: str | None = None,
    device_name: str | None = None,
) -> dict:
    """POST /api/auth/device — initiate device flow. Returns JSON body.

    Optional vault_name is the plugin's local Obsidian vault name. It's stored
    on the device-authorization row so /link can pre-fill the create-new field.
    """
    payload: dict = {"client_id": client_id}
    if vault_name is not None:
        payload["vault_name"] = vault_name
    if device_name is not None:
        payload["device_name"] = device_name
    resp = requests.post(
        f"{API_URL}/auth/device",
        json=payload,
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()


def device_authorize(
    jwt_token: str, user_code: str, vault_id: str, label: str | None = None
) -> requests.Response:
    """POST /api/auth/device/authorize — confirm device from user side.
    Returns the raw Response so callers can check 402 cap responses.
    """
    body: dict = {"user_code": user_code, "vault_id": vault_id}
    if label is not None:
        body["label"] = label
    return requests.post(
        f"{API_URL}/auth/device/authorize",
        json=body,
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )


def device_token_poll(device_code: str, *, max_attempts: int = 10) -> dict:
    """POST /api/auth/device/token — poll until 200 (authorized) or give up."""
    import time

    for _ in range(max_attempts):
        resp = requests.post(
            f"{API_URL}/auth/device/token",
            json={"device_code": device_code},
            timeout=10,
        )
        if resp.status_code == 200:
            return resp.json()
        # 400 = authorization_pending (RFC 8628 §3.5); 428 is the pre-2026-08
        # status, kept so this works against either side of a paired rollout.
        # Gate on the BODY: `token/2` has no catch-all clause, so a malformed
        # request 400s too, and treating that as pending would burn all ten
        # attempts before failing with a misleading timeout.
        if resp.status_code in (400, 428) and _pending_body(resp):
            time.sleep(0.5)
            continue
        resp.raise_for_status()

    raise TimeoutError(f"device_token_poll: still pending after {max_attempts} attempts")


def create_vault(jwt_token: str, name: str) -> int:
    """POST /api/vaults/register: create a vault. Returns vault_id.

    The only create endpoint, idempotent by client_id, and it responds with
    the vault flat (no "vault" wrapper). The name is already unique per call
    here, so it doubles as the idempotency key.
    """
    resp = requests.post(
        f"{API_URL}/vaults/register",
        json={"name": name, "client_id": name},
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["id"]


def revoke_device(jwt_token: str, family_id: str) -> int:
    """DELETE /api/connections/device/:family_id. Returns HTTP status code."""
    resp = requests.delete(
        f"{API_URL}/connections/device/{family_id}",
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=10,
    )
    return resp.status_code


def _set_obsidian_cap(email: str, cap: int) -> None:
    """Pin BOTH obsidian device caps for a user, via docker exec SQL.

    `obsidian_connections_cap` and `concurrent_devices` count the same thing
    (`Connections.count_active(user_id, :obsidian)`) but gate two different
    endpoints: OAuth consent uses the former, device-flow authorize the
    latter. This helper used to set only `obsidian_connections_cap`, and the
    device-flow test passed anyway because both defaulted to 1 — so it was
    asserting against a default it never actually pinned. When Free moved to
    2 devices the coincidence broke and the test went red against correct
    behaviour. Setting both keeps the pin honest whichever endpoint is under
    test.
    """
    keys = ("obsidian_connections_cap", "concurrent_devices")
    values = ", ".join(
        f"((SELECT id FROM users WHERE email = '{email}'), "
        f"'{key}', '{{\"v\": {cap}}}'::jsonb, 'e2e-test', 'e2e')"
        for key in keys
    )
    sql = (
        f"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES {values} "
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
        raise RuntimeError(f"_set_obsidian_cap failed: {result.stderr.strip()}")


def _lift_rps_cap(email: str) -> None:
    """Set api_rps_cap=1000 so test requests aren't 429'd."""
    sql = (
        f"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES ((SELECT id FROM users WHERE email = '{email}'), "
        f"'api_rps_cap', '{{\"v\": 1000}}'::jsonb, 'e2e-test', 'e2e') "
        f"ON CONFLICT (user_id, key) DO UPDATE SET value = EXCLUDED.value, set_at = NOW()"
    )
    result = subprocess.run(
        [
            "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
            "psql", "-U", "engram", "-d", "engram", "-c", sql,
        ],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"_lift_rps_cap failed: {result.stderr.strip()}")


# ── Device-flow tests ─────────────────────────────────────────────────────────


@pytest.mark.asyncio
async def test_device_flow_connection_appears_in_list(clerk_client):
    """Full device-flow happy path:

    1. POST /api/auth/device → user_code
    2. POST /api/auth/device/authorize (JWT) → ok
    3. POST /api/auth/device/token poll → access+refresh tokens
    4. GET /api/connections → obsidian row with verified=true + family_id as client_id
    5. DELETE /api/connections/device/:family_id → 204
    6. GET /api/connections → obsidian row gone
    """
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    grant_test_plan(email)
    try:
        vault_id = create_vault(jwt, f"e2e-vault-{_ts()}")

        # 1. Start device flow
        start = device_start("e2e-obsidian-plugin")
        device_code = start["device_code"]
        user_code = start["user_code"]

        # 2. User authorizes in browser (simulated with JWT)
        auth_resp = device_authorize(jwt, user_code, vault_id)
        assert auth_resp.status_code == 200, (
            f"authorize failed: {auth_resp.status_code} {auth_resp.text}"
        )

        # 3. Plugin polls for tokens
        tokens = device_token_poll(device_code)
        assert "access_token" in tokens
        assert "refresh_token" in tokens

        # 4. Connections listing includes the device row
        rows = list_connections(jwt)
        obsidian = [r for r in rows if r["kind"] == "obsidian"]
        assert len(obsidian) == 1, f"expected 1 obsidian connection, got {len(obsidian)}"

        row = obsidian[0]
        assert row["verified"] is True, "device-flow connection should be verified"
        assert row["name"] == "Obsidian Vault Sync"
        assert row["software_id"] == "engram-vault-sync"
        family_id = row["client_id"]
        assert family_id is not None, "family_id should be set as client_id"

        # 5. Delete the connection
        status = revoke_device(jwt, family_id)
        assert status == 204, f"expected 204 on device revoke, got {status}"

        # 6. Gone from list
        rows_after = list_connections(jwt)
        obsidian_after = [r for r in rows_after if r["kind"] == "obsidian"]
        assert obsidian_after == [], (
            f"obsidian connection still listed after revoke: {obsidian_after}"
        )

    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_device_flow_vault_name_hint_surfaces_on_link_page(clerk_client):
    """Plugin sends its local Obsidian vault name with the device-flow start;
    the /link consent page reads it back via GET /vaults?user_code=... so the
    "create new vault" field pre-fills with a sensible default.
    """
    clerk_user_id, jwt, _email = _make_clerk_user(clerk_client)
    try:
        start = device_start("e2e-plugin", vault_name="My Obsidian Notes")
        user_code = start["user_code"]

        resp = requests.get(
            f"{API_URL}/vaults",
            params={"user_code": user_code},
            headers={"Authorization": f"Bearer {jwt}"},
            timeout=10,
        )
        resp.raise_for_status()
        body = resp.json()
        assert body["suggested_vault_name"] == "My Obsidian Notes"

        # And without the hint, the field stays absent so the wizard's
        # blank-default UX is preserved.
        start_no_hint = device_start("e2e-plugin-2")
        resp2 = requests.get(
            f"{API_URL}/vaults",
            params={"user_code": start_no_hint["user_code"]},
            headers={"Authorization": f"Bearer {jwt}"},
            timeout=10,
        )
        resp2.raise_for_status()
        assert resp2.json()["suggested_vault_name"] is None
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_device_flow_label_and_device_name_round_trip(clerk_client):
    """The plugin's device_name is offered back on /link, and the label the user
    types there is trimmed, listed as the connection's name and kept across a
    refresh-token rotation. SaaS lane: Clerk session JWT instead of local auth.
    """
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    grant_test_plan(email)
    try:
        vault_id = create_vault(jwt, f"e2e-vault-{_ts()}")
        start = device_start("e2e-obsidian-plugin", vault_name="Hint", device_name="todd-laptop")

        hints = requests.get(
            f"{API_URL}/vaults",
            params={"user_code": start["user_code"]},
            headers={"Authorization": f"Bearer {jwt}"},
            timeout=10,
        )
        hints.raise_for_status()
        assert hints.json()["suggested_device_name"] == "todd-laptop"

        auth_resp = device_authorize(jwt, start["user_code"], vault_id, label="  Work laptop  ")
        assert auth_resp.status_code == 200, auth_resp.text
        tokens = device_token_poll(start["device_code"])

        rows = [r for r in list_connections(jwt) if r["kind"] == "obsidian"]
        assert len(rows) == 1
        assert rows[0]["label"] == "Work laptop"
        assert rows[0]["name"] == "Work laptop"

        refreshed = requests.post(
            f"{API_URL}/auth/token/refresh",
            json={"refresh_token": tokens["refresh_token"]},
            timeout=10,
        )
        assert refreshed.status_code == 200, refreshed.text
        rows_after = [r for r in list_connections(jwt) if r["kind"] == "obsidian"]
        assert len(rows_after) == 1
        assert rows_after[0]["label"] == "Work laptop"

        too_long = device_authorize(
            jwt, device_start("e2e-obsidian-plugin")["user_code"], vault_id, label="a" * 121
        )
        assert too_long.status_code == 422
        assert too_long.json()["error"] == "invalid_label"
    finally:
        clerk_client.delete_user(clerk_user_id)


@pytest.mark.asyncio
async def test_free_tier_cap_blocks_second_device_authorize(clerk_client):
    """Device cap pinned to 1: first plugin authorize succeeds, second 402s.

    The cap is pinned by override rather than taken from the Free default,
    which is 2 devices. What is under test is the enforcement, not the
    number.
    """
    clerk_user_id, jwt, email = _make_clerk_user(clerk_client)
    _set_obsidian_cap(email, 1)
    _lift_rps_cap(email)
    try:
        vault_id = create_vault(jwt, f"e2e-vault-{_ts()}")

        # First device flow → succeeds (0 < cap of 1)
        start1 = device_start("plugin-install-1")
        auth1 = device_authorize(jwt, start1["user_code"], vault_id)
        assert auth1.status_code == 200, (
            f"first authorize should succeed, got {auth1.status_code}: {auth1.text}"
        )
        device_token_poll(start1["device_code"])  # mint the refresh token family

        # Second device flow → 402 (1 >= cap of 1)
        start2 = device_start("plugin-install-2")
        auth2 = device_authorize(jwt, start2["user_code"], vault_id)
        assert auth2.status_code == 402, (
            f"second authorize should be 402, got {auth2.status_code}: {auth2.text}"
        )
        body = auth2.json()
        assert body["error"] == "limit_exceeded"
        assert body["reason"] == "concurrent_devices_exceeded"
        assert body["limit_key"] == "concurrent_devices"
        assert body["current"] == 1
        assert body["limit"] == 1
        # upgrade_url is config-driven (ENGRAM_UPGRADE_URL); SaaS default is
        # the full https://app.engram.page/#settings/billing URL, self-host
        # can override. Assert the path suffix only.
        assert body["upgrade_url"] and body["upgrade_url"].endswith(
            "/#settings/billing"
        ), f"upgrade_url should end with /#settings/billing; got {body['upgrade_url']!r}"
    finally:
        clerk_client.delete_user(clerk_user_id)
