"""Test 02: A creates note → B receives via WebSocket channel without manual pull."""

import pytest

from helpers.vault import wait_for_exact_content, write_note


@pytest.mark.asyncio
async def test_live_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A creates note, B receives it through WebSocket channel — no manual pull triggered."""
    path = "E2E/LiveSyncTest.md"
    content = "# Live Sync Test\nThis should arrive via WebSocket channel."

    # Verify channel is connected on B
    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    # A creates the note
    write_note(vault_a, path, content)

    # Wait for A's push to land on server
    api_sync.wait_for_note(path, timeout=10)

    # B should receive via channel — poll until the FULL body arrives (no manual pull!)
    wait_for_exact_content(vault_b, path, content, timeout=15)
