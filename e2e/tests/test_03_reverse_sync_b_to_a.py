"""Test 03: B creates note → A receives it LIVE. Proves bidirectional live sync."""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import write_note


@pytest.mark.asyncio
async def test_b_creates_a_receives(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Reverse direction: B writes, A receives via WS — no manual pull."""
    path = "E2E/ReverseSync.md"
    content = "# Reverse Sync\nCreated in vault B, should appear in vault A."

    write_note(vault_b, path, content)

    note = api_sync.wait_for_note(path)
    assert note is not None, "Note not on server after B's push"

    received = wait_for_delivery(vault_a, path, api_sync)
    assert content in received
