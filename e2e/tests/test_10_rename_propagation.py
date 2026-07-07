"""Test 10: A renames a file → rename propagates to server and B.

Uses CDP vault.rename() to trigger Obsidian's handleRename (filesystem
mv would not trigger the plugin's rename handler).
"""

import uuid

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_file_gone, write_note


@pytest.mark.asyncio
async def test_rename_propagation(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A renames a synced file, B should see the new path (not delete+create)."""
    # Unique per-run paths (rerun-safety, same pattern as test_49). The A/B
    # Obsidian instances are session-scoped and NOT reset between pytest reruns,
    # so fixed paths let a prior attempt's per-path state (sync-state, note_id
    # map, a peer's leftover copy) contaminate the next attempt: the create
    # echo-suppresses, or the old path is re-pushed and never goes away. A fresh
    # suffix each invocation makes every attempt collision-free. Old/new share
    # one suffix so the rename maps them as a pair.
    suffix = uuid.uuid4().hex[:12]
    old_path = f"E2E/RenameOld-{suffix}.md"
    new_path = f"E2E/RenameNew-{suffix}.md"

    # A creates the note
    write_note(vault_a, old_path, "# Rename Test\nThis file will be renamed.")
    api_sync.wait_for_note(old_path, timeout=10)

    # B receives it live before rename — no manual pull
    wait_for_delivery(vault_b, old_path, api_sync, timeout=30)

    # A renames via Obsidian's vault API (triggers handleRename → POST /notes/rename)
    await cdp_a.rename_file(old_path, new_path)

    # Wait for server to reflect the rename
    api_sync.wait_for_note(new_path, timeout=10)
    api_sync.wait_for_note_gone(old_path, timeout=10)

    # Verify: B has new path, does NOT have old path — both live, no manual pull.
    # The rename reaches B as two separate events (delete old-path + upsert
    # new-path), so the old-path removal can lag the new-path arrival — poll
    # for it rather than asserting a snapshot.
    b_content = wait_for_delivery(vault_b, new_path, api_sync, timeout=30)
    assert "Rename Test" in b_content, "B should have the renamed file"
    wait_for_file_gone(vault_b, old_path, timeout=30)  # B no longer has the old path
