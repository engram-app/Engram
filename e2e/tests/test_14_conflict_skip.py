"""Test 14: Conflict resolved with skip — no changes applied to either side."""

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import read_note


@pytest.mark.asyncio
async def test_conflict_skip(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both edit same note. B resolves with skip → nothing changes."""
    path = "E2E/ConflictSkip.md"

    await setup_conflict(path, vault_a, vault_b, cdp_b, api_sync)

    try:
        # v0.6.0 defaults to "auto" which bypasses onConflict — switch to modal
        await cdp_b.set_conflict_resolution("modal")

        # Override B's handler to skip
        await cdp_b.override_conflict_handler("skip")

        # B catches up — conflict detected, resolved as skip → no changes
        await cdp_b.trigger_catch_up()

        # B should still have B's local content (skip doesn't overwrite)
        b_content = read_note(vault_b, path)
        assert "Edited by B" in b_content, "Skip should preserve B's local content"

        # Server should still have A's content (skip doesn't push)
        note = api_sync.get_note(path)
        assert note is not None, "Server note should still exist"
        assert "Edited by A" in note["content"], "Skip should leave server unchanged"
    finally:
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")
        await cdp_b.resume_outgoing_sync()
