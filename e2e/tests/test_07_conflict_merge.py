"""Test 07: A and B both edit → programmatic merge via overridden onConflict.

Same pause-edit-pull pattern as test_06, but resolves with 'merge'
and verifies the merged content is applied locally. The auto-push of
the merged version to the server is covered by test_15.
"""

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import read_note


@pytest.mark.asyncio
async def test_conflict_merge(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides edit. B resolves with a custom merge."""
    path = "E2E/ConflictMerge.md"
    merged = "# Conflict Test\nMerged content from both A and B"

    await setup_conflict(
        path, vault_a, vault_b, cdp_b, api_sync,
        a_edit="Edited by A for merge",
        b_edit="Edited by B for merge",
        base_content="Base content for merge",
    )

    try:
        await cdp_b.set_conflict_resolution("modal")
        await cdp_b.override_conflict_handler("merge", merged_content=merged)

        await cdp_b.trigger_pull()

        b_content = read_note(vault_b, path)
        assert "Merged content from both A and B" in b_content, (
            f"Expected merged content, got: {b_content[:200]}"
        )
    finally:
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")
        await cdp_b.resume_outgoing_sync()
