"""Test 30: Channel catch-up pull covers multiple missed changes.

When the WebSocket channel reconnects after a gap, the onStatusChange(true)
callback triggers a pull() that fetches ALL changes since the last sync
cursor — not just the latest one. This test creates multiple notes while
the channel is down and verifies all are delivered on reconnect.
"""

import asyncio
import time

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_channel_catch_up_multi(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Channel drops, A creates 3 notes, channel reconnects, B gets all 3."""
    paths = [
        "E2E/ChannelCatchUp1.md",
        "E2E/ChannelCatchUp2.md",
        "E2E/ChannelCatchUp3.md",
    ]

    # Defensive: ensure A is online (previous test may have failed mid-offline)
    if await cdp_a.get_offline_status():
        await cdp_a.restore_online()
        await asyncio.sleep(1)

    # Disconnect B's channel
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_stream_connected(), "B's channel should be disconnected"

    try:
        # A creates 3 notes while B's channel is down. The nonce keeps the
        # content unique per attempt: on a flake RERUN the notes already exist
        # server-side from attempt 1, and a byte-identical re-push
        # short-circuits (no new seq, no broadcast) — so B's catch-up would
        # legitimately have nothing new to deliver and the rerun always fails.
        nonce = time.time()
        for i, path in enumerate(paths, 1):
            write_note(vault_a, path, f"# Channel Catch Up {i} ({nonce})\nMissed while disconnected")

        # Wait for all to reach server
        for path in paths:
            api_sync.wait_for_note(path)

        # Reconnect B's channel — triggers catch-up pull
        await cdp_b.reconnect_stream()

        # All 3 should arrive in B's vault via catch-up pull
        for path in paths:
            b_content = wait_for_file(vault_b, path)
            assert "Missed while disconnected" in b_content, (
                f"{path} not received after channel catch-up: {b_content[:200]}"
            )
    finally:
        # Ensure B's channel is reconnected even on failure
        if not await cdp_b.check_stream_connected():
            await cdp_b.reconnect_stream()
