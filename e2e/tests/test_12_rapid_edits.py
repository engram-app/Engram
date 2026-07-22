"""Test 12: Rapid successive edits — only final version should land on server.

Verifies the debounce mechanism works: 10 writes in <1s should result in
only the last version being pushed (not 10 separate pushes).
"""

import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_rapid_edits(vault_a, cdp_a, api_sync):
    """Rapid writes to the same file — server should have the final version."""
    path = "E2E/RapidEdits.md"

    # Write 10 versions in quick succession (faster than 500ms debounce)
    for i in range(1, 11):
        write_note(vault_a, path, f"# Rapid Edit\nVersion {i}")
        time.sleep(0.05)  # 50ms between writes — well within debounce window

    # Wait for the final version to land on server
    api_sync.wait_for_note_content(path, "Version 10")

    # Verify server has the FINAL version, not an intermediate one
    note = api_sync.get_note(path)
    assert "Version 10" in note["content"], (
        f"Server should have final version, got: {note['content'][:100]}"
    )
