"""Test 87: Empty-folder create AND delete propagate live to other clients.

Covers the folder-propagation seams (backend PR #987 + plugin PR #220):
  - POST /folders broadcasts folders.batch create -> plugins materialize the
    empty directory live (no note inside it).
  - DELETE /folders/*path broadcasts folders.batch delete -> plugins trash the
    now-empty, previously-tracked folder live (syncExplicitFolders removal
    reconcile). Before the fix the note left but the empty marker folder
    survived forever.

Uses api_sync as the originating client (stands in for the web app); both
Obsidian instances A and B are receivers, so this exercises the broadcast +
the plugin's resync/trash on two independent clients at once.
"""

import pytest

from helpers.vault import wait_for_folder, wait_for_folder_gone


@pytest.mark.asyncio
async def test_empty_folder_create_propagates(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """An explicit empty folder created server-side materializes live on A and B."""
    folder = "E2E/EmptyDir87"

    status = api_sync.create_folder(folder)
    assert status in (200, 201), f"create_folder should succeed, got {status}"

    # Both clients materialize the empty directory live (no manual pull).
    wait_for_folder(vault_a, folder)
    wait_for_folder(vault_b, folder)


@pytest.mark.asyncio
async def test_empty_folder_delete_propagates(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Deleting an empty folder server-side trashes it live on A and B.

    This is the seam that was missing: an *explicit* folder is exempt from the
    plugin's removeEmptyFolders cleanup, so nothing but the delete-broadcast +
    removal reconcile can take it away. Regression guard against "note left,
    folder survived".
    """
    folder = "E2E/DoomedDir87"

    # Create + confirm both clients have the empty folder before deleting.
    assert api_sync.create_folder(folder) in (200, 201)
    wait_for_folder(vault_a, folder)
    wait_for_folder(vault_b, folder)

    # Delete it server-side (stands in for a web-app folder delete).
    assert api_sync.delete_folder(folder) == 204

    # Both clients trash the now-empty folder live — no manual pull backstop.
    wait_for_folder_gone(vault_a, folder)
    wait_for_folder_gone(vault_b, folder)
