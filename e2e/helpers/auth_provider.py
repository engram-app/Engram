"""Unified auth provider abstraction for E2E tests.

Dispatches user provisioning based on AUTH_PROVIDER env var.
Each provider knows how to create a user and return an API key
for downstream test fixtures. Tests don't care which provider
bootstrapped the user — they just get an API key.

Usage in conftest.py:
    provider = get_auth_provider(api_url)
    user_id, api_key = provider.provision_user(email, password)
    # ... later ...
    provider.cleanup_user(user_id)
"""

from __future__ import annotations

import logging
import os
from abc import ABC, abstractmethod

import requests

logger = logging.getLogger(__name__)

AUTH_PROVIDER = os.environ.get("AUTH_PROVIDER", "local")


class AuthProvider(ABC):
    """Base class for E2E auth provider adapters."""

    def __init__(self, api_url: str):
        self.api_url = api_url.rstrip("/")

    @abstractmethod
    def provision_user(self, email: str, password: str) -> tuple[str, str]:
        """Create a user and return (provider_user_id, api_key).

        provider_user_id: opaque ID for cleanup (Clerk user ID or DB user ID)
        api_key: engram_ prefixed API key for test fixtures
        """

    @abstractmethod
    def cleanup_user(self, provider_user_id: str) -> None:
        """Best-effort cleanup of a provisioned user."""

    @abstractmethod
    def cleanup_all_e2e_users(self, run_id: str | None = None, job_id: str | None = None) -> int:
        """Sweep e2e-* users for ``run_id`` (defaults to None = all runs).

        Callers in the pytest session pass the current run id so they only
        delete their own users — never sibling CI runs' users. The reaper
        script omits ``run_id`` and pairs the sweep with a time-based filter
        instead. See issue #160.
        """


class ClerkAuthProvider(AuthProvider):
    """Provisions users via Clerk Backend API + Engram API key creation."""

    def __init__(self, api_url: str, clerk_secret: str):
        super().__init__(api_url)
        from helpers.clerk import ClerkClient
        from helpers.clerk_auth import ClerkAuth

        self.clerk_client = ClerkClient(clerk_secret)
        self._ClerkAuth = ClerkAuth

    def provision_user(self, email: str, password: str) -> tuple[str, str]:
        # 1. Create user in Clerk
        clerk_user_id = self.clerk_client.create_user(email, password)
        logger.info("Provisioned Clerk user: %s (%s)", clerk_user_id, email)

        # 2. Create API key via Engram using Clerk JWT
        clerk_auth = self._ClerkAuth(self.clerk_client, clerk_user_id)
        session = requests.Session()
        session.auth = clerk_auth
        resp = session.post(
            f"{self.api_url}/api-keys",
            json={"name": "e2e-test-key"},
            timeout=10,
        )
        if resp.status_code != 200:
            raise RuntimeError(
                f"API key creation via Clerk auth failed: {resp.status_code}\n{resp.text[:500]}"
            )
        api_key = resp.json().get("key")
        if not api_key:
            raise RuntimeError(f"No key in API key response: {resp.json()}")

        logger.info("Created API key for %s: %s...", email, api_key[:20])

        # 3. Auto-complete onboarding so vault-scoped tests don't hit 403.
        prof_resp = session.patch(
            f"{self.api_url}/onboarding/profile",
            json={"uses_obsidian": True, "tools": ["claude"]},
            timeout=10,
        )
        if prof_resp.status_code not in (200, 201):
            raise RuntimeError(
                f"Onboarding profile PATCH failed: {prof_resp.status_code}\n{prof_resp.text[:500]}"
            )

        return clerk_user_id, api_key

    def cleanup_user(self, provider_user_id: str) -> None:
        try:
            self.clerk_client.delete_user(provider_user_id)
        except Exception as e:
            logger.warning("Failed to delete Clerk user %s: %s", provider_user_id, e)

    def cleanup_all_e2e_users(self, run_id: str | None = None, job_id: str | None = None) -> int:
        from helpers.cleanup import cleanup_all_e2e_clerk_users
        return cleanup_all_e2e_clerk_users(self.clerk_client, run_id=run_id, job_id=job_id)

    def get_clerk_auth(self, clerk_user_id: str):
        """Return a ClerkAuth adapter for direct JWT auth (OAuth tests)."""
        return self._ClerkAuth(self.clerk_client, clerk_user_id)


class LocalAuthProvider(AuthProvider):
    """Provisions users via local register endpoint + API key creation."""

    def provision_user(self, email: str, password: str) -> tuple[str, str]:
        # 1. Register via local auth endpoint
        resp = requests.post(
            f"{self.api_url}/auth/register",
            json={"email": email, "password": password},
            timeout=10,
        )
        if resp.status_code != 201:
            raise RuntimeError(
                f"Local registration failed for {email}: {resp.status_code}\n{resp.text[:500]}"
            )
        body = resp.json()
        access_token = body["access_token"]
        logger.info("Registered local user: %s", email)

        # 2. Create API key using the access token
        resp = requests.post(
            f"{self.api_url}/api-keys",
            headers={"Authorization": f"Bearer {access_token}"},
            json={"name": "e2e-test-key"},
            timeout=10,
        )
        if resp.status_code != 200:
            raise RuntimeError(
                f"API key creation failed for {email}: {resp.status_code}\n{resp.text[:500]}"
            )
        api_key = resp.json().get("key")
        if not api_key:
            raise RuntimeError(f"No key in API key response: {resp.json()}")

        # Auto-complete onboarding so vault-scoped tests don't hit 403.
        prof_resp = requests.patch(
            f"{self.api_url}/onboarding/profile",
            headers={"Authorization": f"Bearer {access_token}"},
            json={"uses_obsidian": True, "tools": ["claude"]},
            timeout=10,
        )
        if prof_resp.status_code not in (200, 201):
            raise RuntimeError(
                f"Onboarding profile PATCH failed for {email}: {prof_resp.status_code}\n{prof_resp.text[:500]}"
            )

        # Use email as provider_user_id for local (no external ID to track)
        logger.info("Created API key for %s: %s...", email, api_key[:20])
        return email, api_key

    def cleanup_user(self, provider_user_id: str) -> None:
        # Local users are cleaned up via DB cleanup in session teardown
        pass

    def cleanup_all_e2e_users(self, run_id: str | None = None, job_id: str | None = None) -> int:  # noqa: ARG002
        # No external service to clean — DB cleanup handles it
        return 0


def get_auth_provider(api_url: str) -> AuthProvider:
    """Factory: returns the right AuthProvider based on AUTH_PROVIDER env var."""
    if AUTH_PROVIDER == "clerk":
        clerk_secret = os.environ.get("E2E_CLERK_SECRET_KEY", "")
        if not clerk_secret:
            raise RuntimeError("AUTH_PROVIDER=clerk but E2E_CLERK_SECRET_KEY not set")
        return ClerkAuthProvider(api_url, clerk_secret)
    elif AUTH_PROVIDER == "local":
        return LocalAuthProvider(api_url)
    else:
        raise RuntimeError(f"Unknown AUTH_PROVIDER: {AUTH_PROVIDER}")
