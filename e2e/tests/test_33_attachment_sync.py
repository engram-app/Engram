"""Test 33: Binary attachment syncs from vault A to vault B.

A creates a small PNG in the vault. The plugin detects it as a binary
extension, pushes via pushAttachment. B receives it live with identical
bytes. Deletion on A propagates to server and then to B live.
"""

import pytest

from helpers.log_oracle import wait_for_binary_delivery
from helpers.vault import wait_for_file_gone, write_binary


# Minimal valid PNG: 1x1 red pixel
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


@pytest.mark.asyncio
async def test_attachment_push_and_pull(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A writes a PNG → server stores it → B receives identical bytes live."""
    att_path = "E2E/attachments/test33.png"

    write_binary(vault_a, att_path, TINY_PNG)
    api_sync.wait_for_attachment(att_path)

    b_data = wait_for_binary_delivery(vault_b, att_path, api_sync)
    assert b_data == TINY_PNG, (
        f"B's attachment bytes should match. Got {len(b_data)} bytes, expected {len(TINY_PNG)}"
    )


@pytest.mark.asyncio
async def test_attachment_delete_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Deleting an attachment on A removes it from server and B live."""
    att_path = "E2E/attachments/test33del.png"

    # Setup: A creates, server receives, B receives a copy live.
    write_binary(vault_a, att_path, TINY_PNG)
    api_sync.wait_for_attachment(att_path)
    wait_for_binary_delivery(vault_b, att_path, api_sync)

    # A deletes — vault.delete fires handleDelete on A, which calls
    # /attachments DELETE. Server reflects the soft-delete as 404.
    (vault_a / att_path).unlink()
    api_sync.wait_for_attachment_gone(att_path)

    # B removes it live — no manual pull backstop
    wait_for_file_gone(vault_b, att_path)
