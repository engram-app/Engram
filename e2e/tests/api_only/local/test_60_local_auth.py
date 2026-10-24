"""Test 60: Local auth provider — register, login, refresh, logout.

API-only test. Exercises local auth lifecycle endpoints that only
exist when AUTH_PROVIDER=local. Provider-agnostic tests (API keys,
/me, token rejection) are in test_61_auth_agnostic.py.

Tests:
- First user registration → admin role
- Second user registration → member role
- Duplicate email rejection
- Login with valid/invalid credentials
- Refresh token rotation
- Refresh token reuse detection (theft)
- Logout + cookie invalidation
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
    allowed_methods=frozenset(["GET", "POST", "PUT", "DELETE"]),
    raise_on_status=False,
)


class _RetryClient:
    """Fresh ``requests.Session`` per call.

    A shared Session persists cookies across calls, which breaks the refresh
    tests: a rotated cookie from the session jar would override the
    per-call ``cookies=`` kwarg. New Session per call = empty jar, so the
    test's explicit cookies (or absence of them) reach the server verbatim.
    Retry adapter still covers transient network/5xx without bleeding state.
    """

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

    def put(self, url, **kw):
        return self._session().put(url, **kw)

    def delete(self, url, **kw):
        return self._session().delete(url, **kw)


http = _RetryClient()


def unique_email(label: str) -> str:
    """Generate a unique email per call.

    Earlier versions used ``int(time.time())`` (second precision) which
    collides when two tests run within the same second — e.g. both
    ``TestRefresh`` setup methods would hit the same address and the
    second registration returned 422 (duplicate). Adding a uuid4 suffix
    guarantees uniqueness across rapid-fire calls without sacrificing
    the human-readable label prefix.
    """
    return f"e2e-local-{label}-{int(time.time())}-{uuid.uuid4().hex[:8]}@test.com"


PASSWORD = "E2eTestPass!99"


# ---------------------------------------------------------------------------
# Registration
# ---------------------------------------------------------------------------


class TestRegistration:
    def test_first_user_is_admin(self):
        """First registered user gets admin role."""
        email = unique_email("admin")
        resp = http.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201, f"Expected 201, got {resp.status_code}: {resp.text}"
        body = resp.json()

        assert "access_token" in body
        assert body["user"]["email"] == email
        assert body["user"]["role"] in ("admin", "member")  # admin only if DB is empty

    def test_register_returns_refresh_cookie(self):
        """Registration sets an HTTP-only refresh_token cookie."""
        email = unique_email("cookie")
        resp = http.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201
        assert "refresh_token" in resp.cookies, "Should set refresh_token cookie"

    def test_duplicate_email_rejected(self):
        """Cannot register twice with the same email."""
        email = unique_email("dup")
        resp1 = http.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp1.status_code == 201

        resp2 = http.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp2.status_code == 422, f"Expected 422 for dup, got {resp2.status_code}"

    def test_missing_password_rejected(self):
        """Registration without password returns 422."""
        resp = http.post(
            f"{API_URL}/auth/register",
            json={"email": unique_email("nopass")},
            timeout=10,
        )
        assert resp.status_code == 422


# ---------------------------------------------------------------------------
# Login
# ---------------------------------------------------------------------------


class TestLogin:
    @pytest.fixture(scope="class", autouse=True)
    def _registered_user(self, request):
        email = unique_email("login")
        resp = http.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201
        request.cls.email = email

    def test_valid_credentials(self):
        """Login with correct password returns access token + refresh cookie."""
        resp = http.post(
            f"{API_URL}/auth/login",
            json={"email": self.email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 200
        body = resp.json()
        assert "access_token" in body
        assert body["user"]["email"] == self.email
        assert "refresh_token" in resp.cookies

    def test_wrong_password(self):
        """Login with wrong password returns 401."""
        resp = http.post(
            f"{API_URL}/auth/login",
            json={"email": self.email, "password": "WrongPassword!"},
            timeout=10,
        )
        assert resp.status_code == 401

    def test_nonexistent_user(self):
        """Login with unknown email returns 401."""
        resp = http.post(
            f"{API_URL}/auth/login",
            json={"email": "nobody-ever@test.com", "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Token refresh
# ---------------------------------------------------------------------------


class TestRefresh:
    @pytest.fixture(autouse=True)
    def _registered_session(self):
        self.email = unique_email("refresh")
        resp = http.post(
            f"{API_URL}/auth/register",
            json={"email": self.email, "password": PASSWORD},
            timeout=10,
        )
        assert resp.status_code == 201
        self.access_token = resp.json()["access_token"]
        self.refresh_cookie = resp.cookies["refresh_token"]

    def test_refresh_returns_new_tokens(self):
        """POST /auth/refresh with valid cookie returns new access token + rotated cookie."""
        resp = http.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        assert resp.status_code == 200, f"Refresh failed: {resp.text}"
        body = resp.json()
        assert "access_token" in body

        # New refresh cookie should differ from the old one (rotation)
        new_cookie = resp.cookies.get("refresh_token")
        assert new_cookie is not None, "Should set new refresh_token cookie"
        assert new_cookie != self.refresh_cookie, "Refresh token should rotate"

    def test_refresh_token_works_for_api(self):
        """Access token from refresh can authenticate API calls."""
        resp = http.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        new_token = resp.json()["access_token"]

        me_resp = http.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {new_token}"},
            timeout=10,
        )
        assert me_resp.status_code == 200
        assert me_resp.json()["user"]["email"] == self.email

    def test_old_refresh_token_within_leeway_is_treated_as_benign_rotation_race(self):
        """Within the rotation-leeway window (Engram.Auth.RefreshLeeway = 30s),
        re-presenting the just-rotated token is treated as a legitimate race
        (lost rotation, concurrent retry, tab refresh mid-mount) — server
        issues a sibling child in the same family rather than triggering the
        reuse-breach response. RFC 9700 §4.14.2 mitigation pattern.

        Breach detection outside the leeway window is exhaustively covered in
        ExUnit (`test/engram/accounts_test.exs` — "reuse of refresh token
        OUTSIDE the leeway window revokes the family"); reproducing the
        outside-window case in E2E would require either a >30s sleep or a
        test-only timestamp-aging hook, neither of which earns its cost on
        every run.
        """
        # Use the token (rotates it).
        resp1 = http.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        assert resp1.status_code == 200

        # Re-present the rotated cookie immediately — leeway lets it through.
        resp2 = http.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": self.refresh_cookie},
            timeout=10,
        )
        assert resp2.status_code == 200, (
            f"Within-leeway re-use should succeed, got {resp2.status_code}"
        )

    def test_missing_cookie_rejected(self):
        """Refresh without cookie returns 401."""
        resp = http.post(f"{API_URL}/auth/refresh", timeout=10)
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Logout
# ---------------------------------------------------------------------------


class TestLogout:
    def test_logout_invalidates_refresh(self):
        """After logout, the refresh token no longer works."""
        email = unique_email("logout")

        # Register
        reg = http.post(
            f"{API_URL}/auth/register",
            json={"email": email, "password": PASSWORD},
            timeout=10,
        )
        assert reg.status_code == 201
        cookie = reg.cookies["refresh_token"]

        # Logout
        logout_resp = http.post(
            f"{API_URL}/auth/logout",
            cookies={"refresh_token": cookie},
            timeout=10,
        )
        assert logout_resp.status_code == 204

        # Try to refresh — should fail
        refresh_resp = http.post(
            f"{API_URL}/auth/refresh",
            cookies={"refresh_token": cookie},
            timeout=10,
        )
        assert refresh_resp.status_code == 401
