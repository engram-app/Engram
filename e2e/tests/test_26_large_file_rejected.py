"""Test 26: Notes exceeding the server's 10MB limit are rejected gracefully.

The server checks note size and returns 413 for content > 10MB.
Oversized notes should not be persisted, and the error should not block
other syncs from completing.
"""

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_large_file_rejected(vault_a, cdp_a, api_sync):
    """Note > 10MB is rejected by server, other files still sync."""
    large_path = "E2E/LargeNote.md"
    normal_path = "E2E/NormalAfterLarge.md"

    # Write a note > 10MB
    large_content = "# Large Note\n" + ("x" * (11 * 1024 * 1024))
    write_note(vault_a, large_path, large_content)

    # Write a normal file — should sync fine (no cascading failure from 413)
    write_note(vault_a, normal_path, "# Normal Note\nShould sync after large file rejection")

    # Poll for the normal note — once it arrives, the push cycle has completed
    # and the large note has already been attempted and rejected
    api_sync.wait_for_note(normal_path)

    # Large note should NOT be on server (413 rejection)
    note = api_sync.get_note(large_path)
    assert note is None, "Large note should not be pushed to server"
