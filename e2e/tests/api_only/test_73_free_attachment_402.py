"""E2E test 73 (Free-tier launch §8.4.2): Free user attachment upload → 402,
markdown note alongside it sails through.

Covers the Phase 3 backend behavior:
  - POST /api/attachments on Free tier returns 402 with the standardized
    LimitResponse shape ({error: "limit_reached", reason: "attachments_disabled",
    key: "attachments_enabled", ...}) BEFORE doing any S3 work.
  - POST /api/notes for a plain .md note from the same Free user succeeds.
  - GET /api/notes/<path> returns the note; GET /api/attachments/<path>
    returns 404 (the upload never landed).

Why API-only (and what's NOT covered here):
  Plan §8.4.2 also wants:
    - A Sync Center "needs Pro" marker on the attachment row in the
      plugin's UI.
    - A toast matching /attachment.*skipped/i.
  Those assertions live in the plugin (Phase 7), which has not shipped
  in this repo. The plugin lives in a sibling repo (engram-app/
  Engram-obsidian) and the session-scoped Obsidian fixtures here
  provision Pro-equivalent users via grant_test_plan() — so even if
  Phase 7 shipped, this fixture wouldn't observe the 402 path. The
  plugin-side coverage of the marker + toast will be added either to
  the plugin's own Jest suite or as a follow-up e2e with a Free-tier
  Obsidian fixture variant.

  This test stays as the backend-contract guardrail: when the wire
  returns 402 reason="attachments_disabled", the body shape is exactly
  what the plugin reads to make its "needs Pro" decision.
"""
from __future__ import annotations

import logging
import os
import secrets
from datetime import datetime

import pytest

from helpers.api import ApiClient
from helpers.clerk import ClerkClient
from helpers.clerk_auth import provision_clerk_user

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — Clerk auth required for Free attachment 402 test",
)

# Minimal valid PNG: 1x1 red pixel.
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


def _ts() -> str:
    return datetime.now().strftime("%Y%m%d%H%M%S%f")


def test_free_attachment_blocked_note_passes():
    """Free user: attachment upload 402, markdown upsert 200."""

    clerk = ClerkClient(CLERK_SECRET)
    email = f"e2e-free-att-{_ts()}+clerk_test@example.com"
    password = secrets.token_urlsafe(32)
    _clerk_user_id, clerk_auth, _api_key = provision_clerk_user(
        clerk, email, password, API_URL,
    )
    # Use Clerk JWT auth (not the API key). Free's §G defaults set
    # api_rps_cap=0 / api_write_enabled=false, which gate ALL API-key-
    # authed writes — we'd 429/403 on the create_vault below before ever
    # reaching the attachment 402 we're trying to assert. JWT traffic is
    # exempt from those gates per RequireApiRpsBudget. We still skip
    # grant_test_plan() — the user must stay Free-tier so
    # attachments_enabled=false (the actual key under test) holds.
    api = ApiClient(API_URL, clerk_auth)

    # First call accept_free_tier so the onboarding plug stops gating
    # the vault-scoped pipeline once we open a vault.
    resp = api.session.post(
        f"{api.base_url}/onboarding/accept_free_tier", timeout=10,
    )
    assert resp.status_code == 200, (
        f"accept_free_tier should 200; got {resp.status_code}: {resp.text[:200]}"
    )

    # Create the user's one Free-tier vault.
    vault_resp, vault_status = api.create_vault(f"att-vault-{_ts()}")
    assert vault_status in (200, 201), (
        f"vault create should succeed; got {vault_status}: {vault_resp}"
    )
    vault_id = (vault_resp.get("vault") or {}).get("id")
    assert vault_id, f"vault response missing id: {vault_resp}"
    api_v = api.with_vault(vault_id)

    # ── Markdown note: must succeed ──────────────────────────────────────
    note_path = "note.md"
    api_v.create_note(note_path, "# Free note\n\nNo attachments allowed.")
    server_note = api_v.wait_for_note(note_path, timeout=10)
    assert server_note["path"] == note_path, (
        f"server note path mismatch: {server_note}"
    )

    # ── Attachment upload: must 402 with the standardized shape ──────────
    # We hit the raw session so we can inspect status code + body without
    # ApiClient.upload_attachment swallowing the response.
    import base64, time
    payload = {
        "path": "image.png",
        "content_base64": base64.b64encode(TINY_PNG).decode(),
        "mtime": time.time(),
        "mime_type": "image/png",
    }
    att_resp = api_v.session.post(
        f"{api_v.base_url}/attachments", json=payload, timeout=10,
    )
    assert att_resp.status_code == 402, (
        f"Free attachment upload must 402; got {att_resp.status_code}: "
        f"{att_resp.text[:300]}"
    )

    body = att_resp.json()
    # LimitResponse shape (per spec §4.5):
    #   {error: "limit_exceeded", reason: "<machine_key>",
    #    tier: "free"|"starter"|"pro"|null, limit_key: "<key>"|null,
    #    limit: <int|bool|null>, current: <int|null>, upgrade_url: <str|null>}
    assert body.get("error") == "limit_exceeded", (
        f"402 body should carry error=limit_exceeded; got: {body}"
    )
    assert body.get("reason") == "attachments_disabled", (
        f"402 body should carry reason=attachments_disabled; got: {body}"
    )
    assert body.get("limit_key") == "attachments_enabled", (
        f"402 body should carry limit_key=attachments_enabled; got: {body}"
    )
    assert body.get("tier") == "free", (
        f"402 body should carry tier=free for a Free-tier user; got: {body}"
    )

    # ── Server state: note exists, image does not ────────────────────────
    note_after = api_v.get_note(note_path)
    assert note_after is not None and note_after["path"] == note_path, (
        "note.md should still be on server after blocked attachment"
    )

    att_after = api_v.get_attachment("image.png")
    assert att_after.status_code == 404, (
        f"image.png must be absent (404) after 402 upload; got "
        f"{att_after.status_code}: {att_after.text[:200]}"
    )


@pytest.mark.skip(
    reason=(
        "Plugin Phase 7 not shipped: Sync Center 'needs Pro' marker + "
        "/attachment.*skipped/i toast assertions live in the plugin's "
        "UI. Re-enable once src/views/sync-center.ts surfaces the 402 "
        "row and src/main.ts wires the toast on the attachment-skipped "
        "telemetry. Backend 402 contract is covered by "
        "test_free_attachment_blocked_note_passes above."
    )
)
def test_sync_center_marks_attachment_needs_pro():
    """Placeholder for the plugin-side Sync Center + toast assertions.

    When Phase 7 ships, this will:
      1. Provision a Free Obsidian instance (separate fixture).
      2. write_binary(vault, 'image.png', TINY_PNG)
      3. trigger_full_sync()
      4. CDP-evaluate the Sync Center DOM for a row matching image.png
         with the "needs Pro" marker, and assert a Notice fired matching
         /attachment.*skipped/i.
    """
    raise NotImplementedError
