"""Test 63: Device link naming - label, device_name hint, malformed requests.

API-only, local auth. Covers the wire contract the /link page and the plugin
rely on:

- the plugin's optional `device_name` rides on `POST /auth/device` and is read
  back, for the claiming user only, as `suggested_device_name`
- `label` on `POST /auth/device/authorize` is trimmed, stored on the connection,
  shown in the connections list and survives refresh-token rotation
- a bad label is refused (422) BEFORE a new vault is created
- a request missing `user_code` / `vault_id` is a 400, not a 500
"""

import os
import time
import uuid

import requests

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
PASSWORD = "E2eTestPass!99"
TIMEOUT = 10


def _email(label: str) -> str:
    return f"e2e-link-{label}-{int(time.time())}-{uuid.uuid4().hex[:8]}@test.com"


def _register(label: str) -> str:
    """Register a local user and return its access token."""
    resp = requests.post(
        f"{API_URL}/auth/register",
        json={"email": _email(label), "password": PASSWORD},
        timeout=TIMEOUT,
    )
    assert resp.status_code == 201, f"register failed: {resp.status_code} {resp.text}"
    token = resp.json()["access_token"]
    # Linking is gated on onboarding having a profile, as a real user answers it
    # on the step before they link the plugin.
    prof = requests.patch(
        f"{API_URL}/onboarding/profile",
        json={"uses_obsidian": True, "tools": ["claude"]},
        headers=_auth(token),
        timeout=TIMEOUT,
    )
    assert prof.status_code in (200, 201), f"profile failed: {prof.status_code} {prof.text}"
    return token


def _auth(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def _start(**fields) -> dict:
    resp = requests.post(
        f"{API_URL}/auth/device",
        json={"client_id": "e2e-plugin", **fields},
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, f"start failed: {resp.status_code} {resp.text}"
    return resp.json()


def _link_page(token: str, user_code: str) -> dict:
    resp = requests.get(
        f"{API_URL}/vaults",
        params={"user_code": user_code},
        headers=_auth(token),
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, f"/vaults failed: {resp.status_code} {resp.text}"
    return resp.json()


def _authorize(token: str, **fields) -> requests.Response:
    return requests.post(
        f"{API_URL}/auth/device/authorize",
        json=fields,
        headers=_auth(token),
        timeout=TIMEOUT,
    )


def _tokens(device_code: str) -> dict:
    resp = requests.post(
        f"{API_URL}/auth/device/token",
        json={"device_code": device_code},
        timeout=TIMEOUT,
    )
    assert resp.status_code == 200, f"token exchange failed: {resp.status_code} {resp.text}"
    return resp.json()


def _obsidian_connections(token: str) -> list[dict]:
    resp = requests.get(f"{API_URL}/connections", headers=_auth(token), timeout=TIMEOUT)
    assert resp.status_code == 200, f"/connections failed: {resp.status_code} {resp.text}"
    body = resp.json()
    rows = body["connections"] if isinstance(body, dict) else body
    return [r for r in rows if r["kind"] == "obsidian"]


def _vault_count(token: str) -> int:
    resp = requests.get(f"{API_URL}/vaults", headers=_auth(token), timeout=TIMEOUT)
    assert resp.status_code == 200
    return len(resp.json()["vaults"])


class TestDeviceName:
    def test_device_name_and_vault_name_are_read_back_by_the_claimer(self):
        token = _register("hints")
        start = _start(vault_name="Brain Dump", device_name="  todd-laptop ")

        body = _link_page(token, start["user_code"])

        assert body["user_code_valid"] is True
        assert body["suggested_vault_name"] == "Brain Dump"
        assert body["suggested_device_name"] == "todd-laptop"

    def test_a_device_name_over_64_characters_is_dropped_not_fatal(self):
        token = _register("longname")
        start = _start(vault_name="V", device_name="x" * 65)

        body = _link_page(token, start["user_code"])

        assert body["user_code_valid"] is True
        assert body["suggested_device_name"] is None

    def test_another_user_cannot_read_the_hints_of_a_claimed_code(self):
        owner = _register("owner")
        other = _register("other")
        start = _start(vault_name="Private Vault", device_name="owners-pc")
        assert _link_page(owner, start["user_code"])["suggested_device_name"] == "owners-pc"

        stolen = _link_page(other, start["user_code"])

        assert stolen["user_code_valid"] is False
        assert stolen["suggested_vault_name"] is None
        assert stolen["suggested_device_name"] is None

    def test_an_unknown_code_has_no_device_name(self):
        token = _register("unknown")

        body = _link_page(token, "ZZZZ-ZZZZ")

        assert body["user_code_valid"] is False
        assert body["suggested_device_name"] is None


class TestLabel:
    def test_label_is_trimmed_listed_and_kept_across_token_rotation(self):
        token = _register("label")
        start = _start(vault_name="Labelled", device_name="todd-laptop")

        authz = _authorize(
            token,
            user_code=start["user_code"],
            vault_id="new",
            vault_name="Labelled",
            label="  Work laptop  ",
        )
        assert authz.status_code == 200, authz.text

        tokens = _tokens(start["device_code"])
        rows = _obsidian_connections(token)
        assert len(rows) == 1
        assert rows[0]["label"] == "Work laptop"
        assert rows[0]["name"] == "Work laptop"

        refreshed = requests.post(
            f"{API_URL}/auth/token/refresh",
            json={"refresh_token": tokens["refresh_token"]},
            timeout=TIMEOUT,
        )
        assert refreshed.status_code == 200, refreshed.text
        rows_after = _obsidian_connections(token)
        assert len(rows_after) == 1, "rotation must keep one connection family"
        assert rows_after[0]["label"] == "Work laptop"

    def test_no_label_keeps_the_client_name(self):
        token = _register("nolabel")
        start = _start(vault_name="Plain")

        authz = _authorize(
            token, user_code=start["user_code"], vault_id="new", vault_name="Plain"
        )
        assert authz.status_code == 200, authz.text
        _tokens(start["device_code"])

        rows = _obsidian_connections(token)
        assert rows[0]["label"] is None
        assert rows[0]["name"] == "Obsidian Vault Sync"

    def test_a_blank_label_is_treated_as_no_label(self):
        token = _register("blank")
        start = _start(vault_name="Blank")

        authz = _authorize(
            token,
            user_code=start["user_code"],
            vault_id="new",
            vault_name="Blank",
            label="   ",
        )
        assert authz.status_code == 200, authz.text
        _tokens(start["device_code"])

        assert _obsidian_connections(token)[0]["label"] is None

    def test_an_over_long_label_is_refused_before_a_vault_is_created(self):
        token = _register("toolong")
        before = _vault_count(token)
        start = _start(vault_name="Orphan Check")

        authz = _authorize(
            token,
            user_code=start["user_code"],
            vault_id="new",
            vault_name="Orphan Check",
            label="a" * 121,
        )

        assert authz.status_code == 422
        assert authz.json()["error"] == "invalid_label"
        assert _vault_count(token) == before, "a refused label must not leave a vault behind"


class TestMalformedAuthorize:
    def test_missing_user_code_or_vault_id_is_a_400(self):
        token = _register("malformed")

        for fields in (
            {"vault_id": str(uuid.uuid4())},
            {"user_code": "AAAA-BBBB"},
            {"label": "x"},
        ):
            resp = _authorize(token, **fields)
            assert resp.status_code == 400, f"{fields}: {resp.status_code} {resp.text}"
            assert resp.json()["error"] == "invalid_request"
