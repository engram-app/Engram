"""Test 10: A renames a file → rename propagates to server and B.

Uses CDP vault.rename() to trigger Obsidian's handleRename (filesystem
mv would not trigger the plugin's rename handler).

Post id-keying (#925/#180): the renamed note keeps its stable note_id and
its live CRDT room; the server moves/resurrects the row by id rather than
delete+recreate. This suite pairs backend main against plugin main to verify
the two note_id-keyed sides agree.
"""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_rename_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A renames a synced file, B should see the new path (not delete+create)."""
    old_path = "E2E/RenameOld.md"
    new_path = "E2E/RenameNew.md"

    # A creates the note
    write_note(vault_a, old_path, "# Rename Test\nThis file will be renamed.")
    api_sync.wait_for_note(old_path, timeout=10)

    # Sync to B
    await cdp_b.trigger_full_sync()
    assert (vault_b / old_path).exists(), "B should have the note before rename"

    # A renames via Obsidian's vault API (triggers handleRename → POST /notes/rename)
    await cdp_a.rename_file(old_path, new_path)

    # Wait for server to reflect the rename
    api_sync.wait_for_note(new_path, timeout=10)
    api_sync.wait_for_note_gone(old_path, timeout=10)

    # B pulls
    await cdp_b.trigger_full_sync()

    # Verify: B has new path, does NOT have old path
    b_content = wait_for_delivery(vault_b, new_path, api_sync, timeout=10)
    assert "Rename Test" in b_content, "B should have the renamed file"
    assert not (vault_b / old_path).exists(), "B should not have the old path"
