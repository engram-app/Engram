"""Test 23: Channel disconnect → reconnect → catch-up pull.

When the WebSocket channel drops, the plugin should auto-reconnect (exponential
backoff starting at 1s). On reconnect, onStatusChange(true) triggers a
catch-up pull that fetches any changes missed while disconnected.
"""

import asyncio

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_channel_reconnect_catches_up(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Channel drops, A creates note, channel reconnects, B gets the note."""
    path = "E2E/ChannelReconnect.md"

    # Wait for channel to be connected on B (may take a moment after prior tests)
    await cdp_b.wait_for_stream_connected(timeout=10)

    # Disconnect B's channel
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_stream_connected(), "B's channel should be disconnected"

    # A creates a note while B's channel is down
    write_note(vault_a, path, "# Channel Reconnect Test\nCreated while B was disconnected")
    api_sync.wait_for_note(path, timeout=10)

    # Reconnect B's channel — triggers catch-up pull
    await cdp_b.reconnect_stream()

    # Wait for catch-up pull to deliver the note
    b_content = wait_for_file(vault_b, path, timeout=15)
    assert "Created while B was disconnected" in b_content, (
        f"B should have received the note via catch-up pull, got: {b_content[:200]}"
    )
