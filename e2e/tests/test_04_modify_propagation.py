"""Test 04: A modifies a file → updated content propagates to B."""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_content, write_note


@pytest.mark.asyncio
async def test_modify_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A edits an existing synced note, B receives the update — no manual pull."""
    path = "E2E/ModifyTest.md"
    v1 = "# Modify Test\nVersion 1"
    v2 = "# Modify Test\nVersion 2 — updated by A"

    # A creates initial version
    write_note(vault_a, path, v1)
    api_sync.wait_for_note(path, timeout=10)

    # B receives it live (first delivery — file doesn't exist on B yet)
    received = wait_for_delivery(vault_b, path, api_sync, timeout=30)
    assert v1 in received

    # A modifies the note
    write_note(vault_a, path, v2)

    # Poll server until update lands
    api_sync.wait_for_note_content(path, "Version 2", timeout=10)

    # B receives the update live — no manual pull. B's file already exists
    # (from v1 above) so the delivery oracle's non-empty guard can't detect
    # this specific update; wait_for_content polls for the new marker text
    # instead, which is still a pure vault-disk poll with no pull involved.
    received = wait_for_content(vault_b, path, "Version 2", timeout=30)
    assert v2 in received, "Full v2 body should replace v1, not merge/duplicate"
