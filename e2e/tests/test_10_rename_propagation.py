"""Test 10: A renames a file → rename propagates to server and B.

Uses CDP vault.rename() to trigger Obsidian's handleRename (filesystem
mv would not trigger the plugin's rename handler).
"""

import uuid

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_rename_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A renames a synced file, B should see the new path (not delete+create)."""
    # Unique per-run paths (rerun-safety): the Obsidian A/B instances are
    # session-scoped and NOT reset between pytest-rerunfailures attempts, so a
    # fixed path lets a prior attempt's leftover RenameNew on B — plus its
    # "RenameOld was renamed away" synced state — resurrection-DELETE the fresh
    # RenameOld this attempt creates on A, stranding it 404 for the whole
    # wait_for_note window. A fresh suffix each invocation makes every attempt
    # collision-free (same pattern as test_49). Old/new share one suffix so the
    # rename maps them as a pair.
    suffix = uuid.uuid4().hex[:12]
    old_path = f"E2E/RenameOld-{suffix}.md"
    new_path = f"E2E/RenameNew-{suffix}.md"

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
