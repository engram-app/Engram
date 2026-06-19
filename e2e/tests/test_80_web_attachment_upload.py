"""Test 80: Web-originated attachment upload converges to a second vault.

Phase 3 of attachment management adds web upload (POST /api/attachments) to the
SPA — previously only the Obsidian plugin could create attachments. This proves
a web-originated upload lands on the server and converges to a second vault
through an explicit pull (`trigger_full_sync`) rather than racing live-socket
delivery, which keeps it deterministic under parallel CI load. Server-side state
is cleaned first so the test is safe under pytest reruns.

`api_sync.upload_attachment` is the REST path the web SPA's upload hook calls
(`POST /api/attachments` with base64 content + mime + mtime) — the same endpoint
and shape the new `useUploadAttachment` mutation hits — so exercising it here
covers the web-origin contract end to end.
"""

import pytest

from helpers.vault import wait_for_binary

# B-side convergence (pull + blob fetch) can lag under parallel CI load — give
# it more room than the suite's 15s default. Matches test_79.
CONVERGE_TIMEOUT = 25

# Minimal valid PNG: 1x1 red pixel (same constant as test_79 / test_33).
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


@pytest.mark.asyncio
async def test_web_upload_converges_via_pull(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A web-originated upload lands on the server and converges to B's vault."""
    path = "E2E/attachments/upload80web.png"
    # Clean slate (idempotent): soft-delete any leftover row from a prior run.
    api_sync.delete_attachment(path)

    # Web-originated upload: POST /api/attachments (the path the SPA upload hook
    # uses). 200 confirms the server accepted + stored it.
    assert api_sync.upload_attachment(path, TINY_PNG, "image/png") == 200
    api_sync.wait_for_attachment(path)

    # B converges on its next explicit pull — the deterministic convergence path.
    await cdp_b.trigger_full_sync()
    assert wait_for_binary(vault_b, path, timeout=CONVERGE_TIMEOUT) == TINY_PNG
