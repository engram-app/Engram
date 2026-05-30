"""Test 62: Self-host account settings — display_name, password change, delete.

API-only test. Exercises the PATCH/DELETE /api/me endpoints introduced in
PR #365 for the self-host Account settings UI. Verifies the contract that
the React `AccountPageLocal` page consumes.

Tests:
- PATCH /api/me updates display_name; GET /api/me echoes it back
- Password change forces re-login (old credentials rejected, new accepted)
- Self-delete soft-deletes and blocks future sign-in
- Last-admin guard blocks the sole admin from self-deleting (409)
- Wrong password on DELETE returns 403, account not soft-deleted
- DELETE without password param returns 400
"""

import os
import time
import uuid

import pytest
import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

_RETRY = Retry(
    total=3,
    backoff_factor=0.2,
    status_forcelist=(502, 503, 504),
    allowed_methods=frozenset(["GET", "POST", "PUT", "DELETE", "PATCH"]),
    raise_on_status=False,
)


class _RetryClient:
    def _session(self) -> requests.Session:
        s = requests.Session()
        adapter = HTTPAdapter(max_retries=_RETRY)
        s.mount("http://", adapter)
        s.mount("https://", adapter)
        return s

    def post(self, url, **kw):
        return self._session().post(url, **kw)

    def get(self, url, **kw):
        return self._session().get(url, **kw)

    def patch(self, url, **kw):
        return self._session().patch(url, **kw)

    def delete(self, url, **kw):
        return self._session().delete(url, **kw)


http = _RetryClient()

PASSWORD = "E2eTestPass!99"
NEW_PASSWORD = "E2eTestPassNew!42"


def unique_email(label: str) -> str:
    return f"e2e-local-acct-{label}-{int(time.time())}-{uuid.uuid4().hex[:8]}@test.com"


def register(email: str, password: str = PASSWORD) -> dict:
    """Register a new user and return the response body (access_token, user)."""
    resp = http.post(
        f"{API_URL}/auth/register",
        json={"email": email, "password": password},
        timeout=10,
    )
    assert resp.status_code == 201, f"register failed: {resp.status_code} {resp.text}"
    return resp.json()


def login(email: str, password: str = PASSWORD):
    return http.post(
        f"{API_URL}/auth/login",
        json={"email": email, "password": password},
        timeout=10,
    )


def auth_header(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


# ---------------------------------------------------------------------------
# Display name
# ---------------------------------------------------------------------------


class TestProfileUpdate:
    def test_patch_me_updates_display_name(self):
        email = unique_email("name")
        body = register(email)
        token = body["access_token"]

        # Pre-condition: display_name absent or null
        me0 = http.get(f"{API_URL}/me", headers=auth_header(token), timeout=10)
        assert me0.status_code == 200
        assert me0.json()["user"].get("display_name") in (None, "")

        patch = http.patch(
            f"{API_URL}/me",
            json={"display_name": "E2E Tester"},
            headers={**auth_header(token), "Content-Type": "application/json"},
            timeout=10,
        )
        assert patch.status_code == 200, patch.text
        assert patch.json()["user"]["display_name"] == "E2E Tester"

        # GET round-trip
        me1 = http.get(f"{API_URL}/me", headers=auth_header(token), timeout=10)
        assert me1.json()["user"]["display_name"] == "E2E Tester"

    def test_patch_me_too_long_returns_422(self):
        email = unique_email("toolong")
        body = register(email)
        token = body["access_token"]

        patch = http.patch(
            f"{API_URL}/me",
            json={"display_name": "x" * 81},
            headers={**auth_header(token), "Content-Type": "application/json"},
            timeout=10,
        )
        assert patch.status_code == 422
        assert patch.json()["error"] == "validation_failed"


# ---------------------------------------------------------------------------
# Password change forces re-login
# ---------------------------------------------------------------------------


class TestPasswordChange:
    def test_change_password_rewires_login(self):
        email = unique_email("pw")
        body = register(email)
        token = body["access_token"]

        change = http.post(
            f"{API_URL}/auth/password/change",
            json={"old_password": PASSWORD, "new_password": NEW_PASSWORD},
            headers={**auth_header(token), "Content-Type": "application/json"},
            timeout=10,
        )
        assert change.status_code == 200, change.text

        # Old credentials must NOT work
        old = login(email, PASSWORD)
        assert old.status_code != 200, f"old password should fail, got {old.status_code}"

        # New credentials MUST work
        new = login(email, NEW_PASSWORD)
        assert new.status_code == 200, f"new password should succeed, got {new.status_code}: {new.text}"


# ---------------------------------------------------------------------------
# Self-delete
# ---------------------------------------------------------------------------


class TestSelfDelete:
    def test_member_delete_blocks_future_login(self):
        # Ensure a separate admin exists so this member's deletion isn't blocked.
        # The first-ever register in the test DB becomes admin; subsequent registers
        # are members. We assume at least one admin exists in CI from earlier tests.
        email = unique_email("delete-member")
        body = register(email)
        token = body["access_token"]

        # Verify pre-condition the freshly registered user is a member, not the
        # sole admin (would trigger the last-admin guard).
        me = http.get(f"{API_URL}/me", headers=auth_header(token), timeout=10)
        assert me.json()["user"]["role"] == "member", (
            "Test expects member; bootstrap admin must already exist"
        )

        dele = http.delete(
            f"{API_URL}/me?password={PASSWORD}",
            headers=auth_header(token),
            timeout=10,
        )
        assert dele.status_code == 200, dele.text
        assert dele.json() == {"ok": True}

        # Deleted user cannot log back in
        again = login(email, PASSWORD)
        assert again.status_code != 200, f"deleted user signed in: {again.status_code}"

    def test_wrong_password_returns_403_and_does_not_delete(self):
        email = unique_email("wrong-pw")
        body = register(email)
        token = body["access_token"]

        dele = http.delete(
            f"{API_URL}/me?password=NotMyPassword",
            headers=auth_header(token),
            timeout=10,
        )
        assert dele.status_code == 403
        assert dele.json()["error"] == "invalid_password"

        # Account still works
        again = login(email, PASSWORD)
        assert again.status_code == 200

    def test_missing_password_returns_400(self):
        email = unique_email("no-pw")
        body = register(email)
        token = body["access_token"]

        dele = http.delete(f"{API_URL}/me", headers=auth_header(token), timeout=10)
        assert dele.status_code == 400
        assert dele.json()["error"] == "password_required"


# Note: the last-admin guard (409 when sole admin attempts delete) is covered
# by `test/engram/accounts/profile_test.exs:60` at the unit level. It is not
# replicated here because the CI test DB hosts multiple admins from concurrent
# tests, making it non-deterministic to assert "this user is the only admin"
# from an E2E perspective.
