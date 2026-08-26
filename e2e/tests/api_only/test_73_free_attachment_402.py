"""E2E test 73: Free-tier attachment behaviour and the 402 wire contract.

Free carries `attachments_all_types: true`, so a Free user uploads images
and PDFs like anyone else. The binding Free limit is the 1 GiB
`attachment_bytes_cap`, not the MIME type. This test asserts:

  - POST /api/attachments with image/png on Free succeeds.
  - With `attachments_all_types` revoked by operator override, the same
    upload returns 402 carrying the standardized LimitResponse shape
    ({error: "limit_exceeded", reason: "attachment_must_be_text",
    limit_key: "attachments_text_only", ...}) BEFORE doing any S3 work.
  - POST /api/notes for a plain .md note from the same Free user succeeds.
  - The successful image is readable; the blocked one is 404.

The 402 half is kept even though no tier reaches it by default: the plugin
reads that exact body to decide its "needs Pro" marker, so the wire
contract still needs a guardrail. The plugin-side marker + toast
assertions live in the plugin repo's own suite.
"""
from __future__ import annotations

import logging
import os
import secrets
import subprocess
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


CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")


def _revoke_all_types(email: str) -> None:
    """Turn attachments_all_types OFF for one user via an operator override.

    No tier defaults to text-only since Free gained every MIME type, so this
    is the only way left to exercise the attachment_must_be_text branch. A DB
    trigger pg_notifies on user_limit_overrides writes, so the per-node
    OverrideCache picks this up without a restart.
    """
    sql = (
        f"INSERT INTO user_limit_overrides (user_id, key, value, reason, set_by) "
        f"VALUES ((SELECT id FROM users WHERE email = '{email}'), "
        f"'attachments_all_types', '{{\"v\": false}}'::jsonb, 'e2e-test', 'e2e') "
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
        raise RuntimeError(f"_revoke_all_types failed: {result.stderr.strip()}")


def test_free_attachment_uploads_and_402_shape():
    """Free user: image upload 200, override -> 402, markdown upsert 200."""

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
    vault_resp, vault_status = api.register_vault(f"att-vault-{_ts()}", f"att-client-{_ts()}")
    assert vault_status in (200, 201), (
        f"vault create should succeed; got {vault_status}: {vault_resp}"
    )
    vault_id = vault_resp.get("id")
    assert vault_id, f"vault response missing id: {vault_resp}"
    api_v = api.with_vault(vault_id)

    # ── Markdown note: must succeed ──────────────────────────────────────
    note_path = "note.md"
    api_v.create_note(note_path, "# Free note\n\nNo attachments allowed.")
    server_note = api_v.wait_for_note(note_path)
    assert server_note["path"] == note_path, (
        f"server note path mismatch: {server_note}"
    )

    # ── Attachment upload on Free: must SUCCEED ──────────────────────────
    # Free carries attachments_all_types=true. The binding Free limit is the
    # 1 GiB attachment_bytes_cap, not the MIME type. We hit the raw session so
    # we can inspect status code + body without ApiClient.upload_attachment
    # swallowing the response.
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
    assert att_resp.status_code in (200, 201), (
        f"Free PNG upload must succeed; got {att_resp.status_code}: "
        f"{att_resp.text[:300]}"
    )

    # ── With the grant revoked: 402 in the standardized shape ────────────
    # No tier defaults to text-only any more, but the gate is still reachable
    # by operator override. The plugin reads this exact body to decide its
    # "needs Pro" marker, so keep the wire contract under test.
    _revoke_all_types(email)
    payload2 = dict(payload, path="image2.png", mtime=time.time())
    blocked = api_v.session.post(
        f"{api_v.base_url}/attachments", json=payload2, timeout=10,
    )
    assert blocked.status_code == 402, (
        f"revoked attachments_all_types must 402; got {blocked.status_code}: "
        f"{blocked.text[:300]}"
    )

    body = blocked.json()
    # LimitResponse shape (per spec §4.5):
    #   {error: "limit_exceeded", reason: "<machine_key>",
    #    tier: "free"|"starter"|"pro"|null, limit_key: "<key>"|null,
    #    limit: <int|bool|null>, current: <int|null>, upgrade_url: <str|null>}
    assert body.get("error") == "limit_exceeded", (
        f"402 body should carry error=limit_exceeded; got: {body}"
    )
    assert body.get("reason") == "attachment_must_be_text", (
        f"402 body should carry reason=attachment_must_be_text; got: {body}"
    )
    assert body.get("limit_key") == "attachments_text_only", (
        f"402 body should carry limit_key=attachments_text_only; got: {body}"
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
    assert att_after.status_code == 200, (
        f"image.png must be present after a successful Free upload; got "
        f"{att_after.status_code}: {att_after.text[:200]}"
    )

    blocked_after = api_v.get_attachment("image2.png")
    assert blocked_after.status_code == 404, (
        f"image2.png must be absent (404) after the 402; got "
        f"{blocked_after.status_code}: {blocked_after.text[:200]}"
    )

# NOTE: the plugin-side Sync Center "needs Pro" marker + attachment-skipped
# toast assertions are NOT covered here — they belong in the plugin's own UI
# tests once that surface ships. The backend 402 contract is covered by
# test_free_attachment_uploads_and_402_shape above. (Removed a perpetually-skipped
# NotImplementedError placeholder that never ran — see the no-skip policy.)
