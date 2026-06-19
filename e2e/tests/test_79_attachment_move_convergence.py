"""Test 79: Web-originated attachment move converges in Obsidian — no duplicate.

A move performed on the web (POST /attachments/rename) repoints the live row to
the new path AND inserts a soft-deleted tombstone at the old path, both stamped
with one per-vault seq in one transaction. That tombstone is the durable
`{old_path, deleted: true}` signal that makes the move converge on every client:

  * Live socket — the backend broadcasts note_changed(kind=attachment)
    delete(old) + upsert(new); the plugin trashes old and writes new.
  * Offline catch-up — a client that missed the ephemeral socket events pulls
    the tombstone (deleted) + the repointed row (live) on reconnect and lands
    in the same final state.

Both paths must leave NO duplicate at the old path (no resurrection).
"""

import asyncio

import pytest

from helpers.vault import wait_for_binary, wait_for_file_gone, write_binary


# Minimal valid PNG: 1x1 red pixel (same constant as test_33).
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


@pytest.mark.asyncio
async def test_attachment_move_converges_via_live_socket(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """B is online: a web move lands the new path and trashes the old — no dup."""
    old_path = "E2E/attachments/move79live-old.png"
    new_path = "E2E/attachments/move79live-new.png"

    # Seed: A creates the attachment, server stores it, B pulls a copy.
    write_binary(vault_a, old_path, TINY_PNG)
    api_sync.wait_for_attachment(old_path)
    await cdp_b.trigger_full_sync()
    wait_for_binary(vault_b, old_path, timeout=15)

    # B is connected to the live channel before the move.
    await cdp_b.wait_for_stream_connected(timeout=10)

    # Web-originated move (repoint + old-path tombstone).
    status = api_sync.rename_attachment(old_path, new_path)
    assert status == 200, f"web move should return 200, got {status}"

    # Server reflects the move: new reachable, old a 404.
    api_sync.wait_for_attachment(new_path)
    api_sync.wait_for_attachment_gone(old_path)

    # B converges over the live socket: new written, old trashed — no duplicate.
    b_data = wait_for_binary(vault_b, new_path, timeout=15)
    assert b_data == TINY_PNG, "B's moved attachment bytes should be intact"
    wait_for_file_gone(vault_b, old_path, timeout=15)


@pytest.mark.asyncio
async def test_attachment_move_converges_offline_catch_up(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """B misses the socket events while disconnected, then catches up — no dup.

    This is the case the durable tombstone exists for: without the old-path
    tombstone in the change feed, B's catch-up pull would see only the
    repointed row at the new path and keep a stale duplicate at the old path.
    """
    old_path = "E2E/attachments/move79offline-old.png"
    new_path = "E2E/attachments/move79offline-new.png"

    # Seed: A creates the attachment, server stores it, B pulls a copy.
    write_binary(vault_a, old_path, TINY_PNG)
    api_sync.wait_for_attachment(old_path)
    await cdp_b.trigger_full_sync()
    wait_for_binary(vault_b, old_path, timeout=15)

    # Take B offline so it misses the ephemeral move broadcasts.
    await cdp_b.wait_for_stream_connected(timeout=10)
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_stream_connected(), "B's channel should be down"

    # Web move happens while B is disconnected.
    status = api_sync.rename_attachment(old_path, new_path)
    assert status == 200, f"web move should return 200, got {status}"
    api_sync.wait_for_attachment(new_path)
    api_sync.wait_for_attachment_gone(old_path)

    # Reconnect → catch-up pull delivers BOTH the upsert(new) and the
    # tombstone(old). B converges with no duplicate.
    await cdp_b.reconnect_stream()
    b_data = wait_for_binary(vault_b, new_path, timeout=15)
    assert b_data == TINY_PNG, "B's moved attachment bytes should be intact"
    wait_for_file_gone(vault_b, old_path, timeout=15)
