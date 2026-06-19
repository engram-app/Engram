"""E2E test 72 (Free-tier launch §8.4.1): Free signup → onboarding → vault → first note.

Covers the happy path a Free user walks from "just signed up" to
"first markdown note synced":

  1. Provision a fresh user via the auth provider (Clerk in CI). The
     helper also PATCHes /onboarding/profile {uses_obsidian: True} as a
     side effect — that gets the user past the questionnaire gate.
  2. POST /api/onboarding/accept_free_tier — stamps free_tier_accepted_at
     (Phase 2 endpoint, gates RequireOnboarding's :subscription_ok lane
     when SaaS billing_enabled is true). Asserted both first-call (200
     with next_step shape) and idempotent second-call.
  3. POST /api/vaults — create the user's first (and only, on Free) vault.
  4. POST /api/notes — create hello.md under that vault.
  5. GET /api/notes/changes — verify the note appears in the manifest.
  6. GET /api/billing/status — verify tier == "free".

Why API-only, not driving Obsidian:
  The session-scoped obsidian_a/b/c fixtures provision via sync_user /
  isolation_user which both call grant_test_plan() — lifting Free-tier
  caps to Pro-equivalent overrides. There's no clean way to bolt a
  fresh, unprivileged user onto the existing fixtures' running Obsidian
  process without rebuilding the whole startup path (vault dir, plugin
  config, CDP port). Since the assertion under test is the BACKEND signup
  flow (onboarding endpoints + tier resolution + first note round-trip),
  driving the real plugin would just add a slow proxy on the same wire-
  level surface. Plugin-side coverage of Free behaviors lives in
  test_73 (attachment 402) and test_71 (vault-limit 402).

CI billing_enabled note:
  ci/compose.yml leaves PADDLE_API_KEY unset → runtime.exs flips
  :billing_enabled to false → Onboarding.status/1 auto-passes
  :subscription_ok regardless of accept_free_tier. We still POST it to
  prove the endpoint accepts the request (idempotent {:ok, user}) and
  responds with the next_step shape the SPA expects.
"""
from __future__ import annotations

import logging
import os
import secrets
from datetime import datetime

import pytest
import requests

from helpers.api import ApiClient
from helpers.clerk import ClerkClient
from helpers.clerk_auth import provision_clerk_user

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — Clerk auth required for Free signup test",
)


def _ts() -> str:
    return datetime.now().strftime("%Y%m%d%H%M%S%f")


def test_free_signup_to_first_note():
    """A fresh Free user can complete onboarding, get a vault, and push a note."""

    # ── 1. Provision a fresh Clerk user + API key ────────────────────────
    clerk = ClerkClient(CLERK_SECRET)
    email = f"e2e-free-signup-{_ts()}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)
    _clerk_user_id, clerk_auth, _api_key = provision_clerk_user(
        clerk, email, password, API_URL,
    )
    # Use Clerk JWT (not the API key) — Free's §G defaults set
    # api_rps_cap=0 / api_write_enabled=false, which by design blocks all
    # API-key-authed writes. JWT-authed traffic (i.e. the SPA flow this
    # test simulates) is exempt from those gates per the RequireApiRpsBudget
    # plug. We can't call grant_test_plan() here either: this user must
    # remain Free-tier so /billing/status returns "free" at the end.
    api = ApiClient(API_URL, clerk_auth)

    # ── 2. Accept Free tier (Phase 2 endpoint) ───────────────────────────
    resp = api.session.post(
        f"{api.base_url}/onboarding/accept_free_tier",
        timeout=10,
    )
    assert resp.status_code == 200, (
        f"POST /api/onboarding/accept_free_tier should 200; got {resp.status_code}: "
        f"{resp.text[:300]}"
    )
    body = resp.json()
    # The endpoint returns the same shape as GET /api/onboarding/status —
    # next_step is a string ("tools" / "vault" / "done") so the SPA can
    # navigate without a second fetch.
    assert "next_step" in body, f"accept_free_tier payload missing next_step: {body}"
    assert isinstance(body["next_step"], str), (
        f"next_step should be a string, got {type(body['next_step']).__name__}"
    )

    # Idempotency: calling again is a no-op {:ok, user_unchanged}.
    resp2 = api.session.post(
        f"{api.base_url}/onboarding/accept_free_tier",
        timeout=10,
    )
    assert resp2.status_code == 200, (
        f"Second accept_free_tier should be idempotent (200); got {resp2.status_code}"
    )

    # ── 3. Create first vault ────────────────────────────────────────────
    vault_resp, vault_status = api.create_vault(f"hello-vault-{_ts()}")
    assert vault_status in (200, 201), (
        f"POST /api/vaults should succeed for Free user with 0 vaults; "
        f"got {vault_status}: {vault_resp}"
    )
    vault_id = (vault_resp.get("vault") or {}).get("id")
    assert vault_id, f"vault response missing id: {vault_resp}"

    api_v = api.with_vault(vault_id)

    # ── 4. Create the first note ─────────────────────────────────────────
    note_path = "hello.md"
    note_content = "# Hello Engram\n\nFirst note on Free tier."
    api_v.create_note(note_path, note_content)

    server_note = api_v.wait_for_note(note_path, timeout=10)
    assert server_note["content"] == note_content, (
        f"server returned wrong content: {server_note}"
    )

    # ── 5. /notes/changes returns the new note ──────────────────────────
    # The endpoint expects an ISO8601 `since`; epoch (2000-01-01) returns
    # the full manifest. Response shape is {changes: [...], server_time}.
    changes = api_v.get_changes(since="2000-01-01T00:00:00Z")
    paths = [n.get("path") for n in changes.get("changes", [])]
    assert note_path in paths, (
        f"/notes/changes should list {note_path!r}; got paths: {paths}"
    )

    # ── 6. /billing/status confirms Free tier ────────────────────────────
    status_resp = api.session.get(f"{api.base_url}/billing/status", timeout=10)
    assert status_resp.status_code == 200, (
        f"/api/billing/status should 200; got {status_resp.status_code}: "
        f"{status_resp.text[:200]}"
    )
    status_body = status_resp.json()
    assert status_body.get("tier") == "free", (
        f"Fresh user with no Paddle subscription must be tier=free; "
        f"got tier={status_body.get('tier')!r}: {status_body}"
    )
