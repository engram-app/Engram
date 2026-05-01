"""Test 61: Provider-agnostic auth tests.

These tests run regardless of AUTH_PROVIDER. They verify behavior
that should work identically with Clerk or local auth:
- /me endpoint returns user info
- API key creation and usage
- Invalid/missing tokens rejected
- Multi-user isolation via /me
"""

import os

import pytest
import requests

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"


class TestMeEndpoint:
    """GET /me works with any auth provider's API key."""

    def test_me_returns_user(self, api_sync, sync_user):
        """/me returns the authenticated user's email."""
        resp = api_sync.session.get(f"{API_URL}/me", timeout=10)
        assert resp.status_code == 200
        assert resp.json()["user"]["email"] == sync_user[0]

    def test_me_different_users(self, api_sync, api_iso, sync_user, isolation_user):
        """Two users see their own data via /me."""
        me_sync = api_sync.session.get(f"{API_URL}/me", timeout=10).json()
        me_iso = api_iso.session.get(f"{API_URL}/me", timeout=10).json()

        assert me_sync["user"]["email"] == sync_user[0]
        assert me_iso["user"]["email"] == isolation_user[0]
        assert me_sync["user"]["id"] != me_iso["user"]["id"]


class TestApiKeyAuth:
    """API key usage — works with any auth provider.

    API key *creation* via API-key auth is intentionally rejected (see
    test_api_key_cannot_mint_more_keys); minting only happens via session
    JWT, which the provision_user fixture exercises during setup.
    """

    def test_existing_api_key_authenticates_user_scoped_route(self, sync_user):
        """The bootstrap API key authenticates /me regardless of provider."""
        api_key = sync_user[2]
        resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": f"Bearer {api_key}"},
            timeout=10,
        )
        assert resp.status_code == 200
        assert resp.json()["user"]["email"] == sync_user[0]

    def test_api_key_cannot_mint_more_keys(self, api_sync):
        """API-key auth on /api-keys returns 403.

        Previously a vault-restricted API key could enumerate, mint, or
        revoke sibling keys for the same user; the EngramWeb.Plugs.RequireSession
        plug now restricts /api-keys/* to session/JWT auth only.
        """
        resp = api_sync.session.post(
            f"{API_URL}/api-keys",
            json={"name": "should-be-rejected"},
            timeout=10,
        )
        assert resp.status_code == 403, f"Expected 403, got {resp.status_code}: {resp.text}"
        assert resp.json().get("error") == "api_key_not_allowed"

    def test_api_key_cannot_list_keys(self, api_sync):
        """API-key auth on GET /api-keys returns 403 — credential enumeration block."""
        resp = api_sync.session.get(f"{API_URL}/api-keys", timeout=10)
        assert resp.status_code == 403
        assert resp.json().get("error") == "api_key_not_allowed"


class TestTokenRejection:
    """Invalid/missing auth rejected — universal, no fixtures needed."""

    def test_invalid_token_rejected(self):
        """Garbage bearer token returns 401."""
        resp = requests.get(
            f"{API_URL}/me",
            headers={"Authorization": "Bearer not.a.real.jwt"},
            timeout=10,
        )
        assert resp.status_code == 401

    def test_no_auth_rejected(self):
        """Request without auth header returns 401."""
        resp = requests.get(f"{API_URL}/me", timeout=10)
        assert resp.status_code == 401
