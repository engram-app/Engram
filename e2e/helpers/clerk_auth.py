"""Clerk-based auth for E2E tests.

Provides:
- ClerkAuth: requests auth adapter that auto-refreshes Clerk JWTs
- provision_clerk_user: creates a Clerk user and returns auth objects for tests
"""

from __future__ import annotations

import logging
import time

import requests
from requests.auth import AuthBase

from helpers.clerk import ClerkClient

logger = logging.getLogger(__name__)


class ClerkAuth(AuthBase):
    """requests auth adapter that auto-refreshes Clerk session tokens.

    Clerk session tokens expire in ~60s. This adapter re-mints a fresh
    token via the Backend API when the current one is >45s old.
    """

    def __init__(self, clerk_client: ClerkClient, user_id: str):
        self.clerk_client = clerk_client
        self.user_id = user_id
        self._token: str | None = None
        self._token_time: float = 0

    def __call__(self, r: requests.PreparedRequest) -> requests.PreparedRequest:
        if self._token is None or time.monotonic() - self._token_time > 45:
            self._token = self.clerk_client.create_session_token(self.user_id)
            self._token_time = time.monotonic()
        r.headers["Authorization"] = f"Bearer {self._token}"
        return r


def provision_clerk_user(
    clerk_client: ClerkClient,
    email: str,
    password: str,
    api_url: str,
) -> tuple[str, ClerkAuth, str]:
    """Create a Clerk user and provision them in Engram.

    Steps:
    1. Create user in Clerk via Backend API
    2. Build a ClerkAuth adapter (auto-refreshing JWT)
    3. Create an API key via Engram API (for Obsidian plugin config)

    Returns:
        (clerk_user_id, clerk_auth, api_key)
        - clerk_user_id: Clerk user ID (for cleanup)
        - clerk_auth: ClerkAuth adapter for ApiClient
        - api_key: Long-lived API key string for Obsidian plugin
    """
    # 1. Create user in Clerk
    clerk_user_id = clerk_client.create_user(email, password)
    logger.info("Provisioned Clerk user: %s (%s)", clerk_user_id, email)

    # 2. Build auth adapter
    clerk_auth = ClerkAuth(clerk_client, clerk_user_id)

    # 3. Create API key via Engram API using Clerk JWT
    #    This also triggers find_or_create_by_clerk_id on the backend,
    #    provisioning the user in our DB through the real auth pipeline.
    session = requests.Session()
    session.auth = clerk_auth
    resp = session.post(
        f"{api_url.rstrip('/')}/api-keys",
        json={"name": "e2e-test-key"},
        timeout=10,
    )
    if resp.status_code != 200:
        raise RuntimeError(
            f"API key creation via Clerk auth failed: HTTP {resp.status_code}\n{resp.text[:500]}"
        )
    api_key = resp.json().get("key")
    if not api_key:
        raise RuntimeError(f"No key in API key response: {resp.json()}")

    logger.info("Created API key via Clerk auth for %s: %s...", email, api_key[:20])

    # Pre-complete onboarding so subsequent /api/notes calls (using either
    # the api_key or the clerk JWT) stop hitting 403 onboarding_required.
    prof = session.patch(
        f"{api_url.rstrip('/')}/onboarding/profile",
        json={"uses_obsidian": True, "tools": ["claude"]},
        timeout=10,
    )
    if prof.status_code not in (200, 201):
        raise RuntimeError(
            f"Onboarding profile PATCH failed: HTTP {prof.status_code}\n{prof.text[:500]}"
        )

    return clerk_user_id, clerk_auth, api_key
