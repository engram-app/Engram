"""Test 03: B creates note → A receives it. Proves bidirectional sync."""

import pytest

from helpers.vault import wait_for_exact_content, write_note


@pytest.mark.asyncio
async def test_b_creates_a_receives(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Reverse direction: B writes, A pulls."""
    path = "E2E/ReverseSync.md"
    content = "# Reverse Sync\nCreated in vault B, should appear in vault A."

    # B creates the note
    write_note(vault_b, path, content)

    # Poll server until B's plugin pushes it
    note = api_sync.wait_for_note(path, timeout=10)
    assert note is not None, "Note not on server after B's push"

    # A pulls
    await cdp_a.trigger_full_sync()

    # Verify the FULL body landed in A's vault (poll — pull write is async)
    wait_for_exact_content(vault_a, path, content, timeout=15)
