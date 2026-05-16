"""Onboarding wizard: new user must accept TOS before reaching the dashboard.

Skipped entirely when billing is disabled (self-host mode). The wizard only
exists on the SaaS deployment — a self-host run sets PADDLE_API_KEY=nil and
Engram.Onboarding.status/1 returns `{enabled: false}`, so RequireOnboarding
never halts. Local CI runs self-host, hosted runs (where the gate matters)
should set PADDLE_API_KEY in docker-compose.
"""

import os
import secrets
from datetime import datetime

import pytest
import requests

from helpers.api import ApiClient
from helpers.auth_provider import get_auth_provider

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")


@pytest.fixture(scope="module")
def onboarding_user():
    """Fresh user for onboarding tests — isolated from sync fixtures."""
    ts = datetime.now().strftime("%Y%m%d%H%M%S%f")
    email = f"e2e-onboard-{ts}@example.com"
    password = secrets.token_urlsafe(32)
    provider = get_auth_provider(API_URL)
    _, api_key = provider.provision_user(email, password)

    status = requests.get(
        f"{API_URL}/onboarding/status",
        headers={"Authorization": f"Bearer {api_key}"},
        timeout=10,
    ).json()
    if not status.get("enabled"):
        pytest.skip("Onboarding wizard disabled (self-host mode); nothing to test.")

    return email, api_key


def test_new_user_gets_onboarding_required_on_protected_route(onboarding_user):
    """A user with no TOS acceptance and no subscription is gated."""
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    resp = api.session.get(f"{API_URL}/folders")
    assert resp.status_code == 403
    body = resp.json()
    assert body["error"] == "onboarding_required"
    assert "terms" in body["missing"]
    assert "subscription" in body["missing"]


def test_status_endpoint_reports_agreement_step(onboarding_user):
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    resp = api.session.get(f"{API_URL}/onboarding/status")
    assert resp.status_code == 200
    body = resp.json()
    assert body["enabled"] is True
    assert body["next_step"] == "agreement"
    assert body["terms_ok"] is False


def test_accept_terms_advances_to_billing_step(onboarding_user):
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    status_before = api.session.get(f"{API_URL}/onboarding/status").json()
    current_version = status_before["current_tos_version"]

    accept = api.session.post(
        f"{API_URL}/onboarding/accept-terms",
        json={"version": current_version},
    )
    assert accept.status_code == 201

    status_after = api.session.get(f"{API_URL}/onboarding/status").json()
    assert status_after["terms_ok"] is True
    assert status_after["next_step"] == "billing"


def test_protected_route_still_403_with_missing_subscription(onboarding_user):
    """Terms accepted but no subscription → gate still blocks, missing=['subscription']."""
    _, api_key = onboarding_user
    api = ApiClient(API_URL, api_key)

    resp = api.session.get(f"{API_URL}/folders")
    assert resp.status_code == 403
    body = resp.json()
    assert body["missing"] == ["subscription"]
