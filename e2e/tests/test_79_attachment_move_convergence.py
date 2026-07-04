"""Test 79: Web-originated attachment move converges in Obsidian — no duplicate.

A move performed on the web (POST /attachments/rename) repoints the live row to
the new path AND inserts a soft-deleted tombstone at the old path, both stamped
with one per-vault seq in one transaction. That durable `{old_path, deleted}`
tombstone is what makes the move converge for a client that pulls the change
feed (the offline / catch-up path) — without it, the pull would see only the
repointed row at the new path and keep a stale duplicate at the old path.

These tests assert convergence through an explicit pull (`trigger_full_sync`)
rather than racing live-socket delivery: the pull path is the one the tombstone
exists for, and it's deterministic under parallel CI load. Each test cleans up
server-side state first so it is safe under pytest reruns (a move mutates shared
vault state irreversibly, so a re-run must start from a known-clean slate).
"""

import asyncio

import pytest

from helpers.log_oracle import wait_for_binary_delivery
from helpers.vault import wait_for_file_gone

# B-side convergence (pull + blob fetch) can lag under parallel CI load — give
# it more room than the suite's 15s default.
CONVERGE_TIMEOUT = 25

# Minimal valid PNG: 1x1 red pixel (same constant as test_33).
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


def _seed_clean(api_sync, *paths):
    """Soft-delete any leftover rows at these paths (idempotent) so the test
    starts from a clean slate even on a pytest rerun after a partial failure."""
    for p in paths:
        api_sync.delete_attachment(p)


@pytest.mark.asyncio
async def test_web_move_converges_via_pull(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A web move lands the new path and trashes the old on B's pull — no dup."""
    old_path = "E2E/attachments/move79pull-old.png"
    new_path = "E2E/attachments/move79pull-new.png"
    _seed_clean(api_sync, old_path, new_path)

    # Seed via the API (web-origin upload → immediately on the server), then B pulls.
    assert api_sync.upload_attachment(old_path, TINY_PNG, "image/png") == 200
    api_sync.wait_for_attachment(old_path)
    await cdp_b.trigger_full_sync()
    wait_for_binary_delivery(vault_b, old_path, api_sync, timeout=CONVERGE_TIMEOUT)

    # Web-originated move: repoint live row + insert old-path tombstone.
    assert api_sync.rename_attachment(old_path, new_path) == 200
    api_sync.wait_for_attachment(new_path)
    api_sync.wait_for_attachment_gone(old_path)

    # B converges on its next pull: the tombstone trashes old, the repointed row
    # writes new — no duplicate left at the old path.
    await cdp_b.trigger_full_sync()
    assert wait_for_binary_delivery(vault_b, new_path, api_sync, timeout=CONVERGE_TIMEOUT) == TINY_PNG
    wait_for_file_gone(vault_b, old_path, timeout=CONVERGE_TIMEOUT)


@pytest.mark.asyncio
async def test_web_move_converges_after_offline_window(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """B is offline during the move, then catches up on reconnect — no dup.

    This is the scenario the durable tombstone is for: B never sees the ephemeral
    move broadcasts, so it must learn the old path is gone purely from the pulled
    change feed.
    """
    old_path = "E2E/attachments/move79offline-old.png"
    new_path = "E2E/attachments/move79offline-new.png"
    _seed_clean(api_sync, old_path, new_path)

    # Seed via the API, then B pulls a copy.
    assert api_sync.upload_attachment(old_path, TINY_PNG, "image/png") == 200
    api_sync.wait_for_attachment(old_path)
    await cdp_b.trigger_full_sync()
    wait_for_binary_delivery(vault_b, old_path, api_sync, timeout=CONVERGE_TIMEOUT)

    # Take B offline so it misses the ephemeral move broadcasts entirely.
    await cdp_b.wait_for_stream_connected(timeout=10)
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_stream_connected(), "B's channel should be down"

    # Web move happens while B is disconnected.
    assert api_sync.rename_attachment(old_path, new_path) == 200
    api_sync.wait_for_attachment(new_path)
    api_sync.wait_for_attachment_gone(old_path)

    # Reconnect, then pull: the catch-up delivers the tombstone(old) + the
    # repointed row(new). B converges with no duplicate.
    await cdp_b.reconnect_stream()
    await cdp_b.trigger_full_sync()
    assert wait_for_binary_delivery(vault_b, new_path, api_sync, timeout=CONVERGE_TIMEOUT) == TINY_PNG
    wait_for_file_gone(vault_b, old_path, timeout=CONVERGE_TIMEOUT)
