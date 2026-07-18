"""Test 05: A deletes a file → deletion propagates to server and B."""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import delete_note, wait_for_file_gone, write_note


@pytest.mark.asyncio
async def test_delete_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A deletes a synced file, B's copy should be removed live — no manual pull."""
    path = "E2E/DeleteTest.md"

    # A creates the note
    write_note(vault_a, path, "# Delete Test\nThis file will be deleted.")
    api_sync.wait_for_note(path, timeout=10)

    # B receives it live before deletion
    wait_for_delivery(vault_b, path, api_sync, timeout=30)

    # A deletes the note
    delete_note(vault_a, path)

    # Poll server until delete propagates (soft-delete → 404)
    api_sync.wait_for_note_gone(path, timeout=10)

    # B removes it live (plugin moves to .trash) — no manual pull backstop
    wait_for_file_gone(vault_b, path, timeout=30)
