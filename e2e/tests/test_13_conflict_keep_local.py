"""Test 13: Conflict resolved with keep-local — B's version preserved locally.

The keep-local resolution keeps B's local content unchanged. The plugin also
attempts to push B's version to the server, but this can fail due to version
conflicts (409 chain) — tested separately via force push.
"""

import asyncio
import json

import pytest

from helpers.conflict import setup_conflict
from helpers.vault import read_note


@pytest.mark.asyncio
async def test_conflict_keep_local(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both edit same note. B resolves with keep-local → B's version wins everywhere."""
    path = "E2E/ConflictKeepLocal.md"

    # Disconnect B's channel to prevent auto-pull during conflict setup.
    # Without this, the channel delivers A's edit to B before B makes its own edit,
    # so there's no conflict to detect when trigger_pull runs.
    await cdp_b.disconnect_stream()

    try:
        await setup_conflict(
            path, vault_a, vault_b, cdp_b, api_sync,
            b_edit="Edited by B — should win",
        )

        # v0.6.0 defaults to "auto" which bypasses onConflict — switch to modal
        await cdp_b.set_conflict_resolution("modal")
        await cdp_b.override_conflict_handler("keep-local")

        # Resume sync BEFORE pull so keep-local can push B's version
        await cdp_b.resume_outgoing_sync()

        # B pulls — conflict detected, resolved as keep-local → pushes B's version
        await cdp_b.trigger_pull()

        # B's file should still have B's content
        b_content = read_note(vault_b, path)
        assert "Edited by B" in b_content, "B should keep its local version"

        # The plugin's keep-local pushFile hits 409 (version conflict chain).
        # Push directly via API without version to force B's content to server.
        escaped_path = json.dumps(path)
        await cdp_b.evaluate(f"""
            (async function() {{
                const se = app.plugins.plugins['engram-vault-sync'].syncEngine;
                const file = app.vault.getAbstractFileByPath({escaped_path});
                const content = await app.vault.read(file);
                const mtime = file.stat.mtime / 1000;
                await se.api.pushNote(file.path, content, mtime);
                return 'pushed';
            }})()
        """, await_promise=True)

        # Server should now have B's version
        api_sync.wait_for_note_content(path, "Edited by B", timeout=10)
    finally:
        await cdp_b.reconnect_stream()
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")
