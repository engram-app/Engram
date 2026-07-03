"""Test 04: A modifies a file → updated content propagates to B."""

import pytest

from helpers.vault import wait_for_exact_content, write_note


@pytest.mark.asyncio
async def test_modify_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A edits an existing synced note, B receives the update."""
    path = "E2E/ModifyTest.md"
    v1 = "# Modify Test\nVersion 1"
    v2 = "# Modify Test\nVersion 2 — updated by A"

    # A creates initial version
    write_note(vault_a, path, v1)
    api_sync.wait_for_note(path, timeout=10)

    # Sync to B
    await cdp_b.trigger_full_sync()
    wait_for_exact_content(vault_b, path, v1, timeout=15)

    # A modifies the note
    write_note(vault_a, path, v2)

    # Poll server until update lands
    api_sync.wait_for_note_content(path, "Version 2", timeout=10)

    # B pulls the update — exact match proves v1 fully replaced, not merged/duplicated
    await cdp_b.trigger_full_sync()
    wait_for_exact_content(vault_b, path, v2, timeout=15)
