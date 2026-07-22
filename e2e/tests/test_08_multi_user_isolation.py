"""Test 08: sync-user's notes are invisible to isolation-user and vice versa."""

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_multi_user_isolation(
    vault_a, vault_c, cdp_a, cdp_c, api_sync, api_iso
):
    """User A (sync-user) and User C (isolation-user) cannot see each other's data."""
    # --- sync-user creates a note ---
    sync_path = "E2E/SyncUserSecret.md"
    write_note(vault_a, sync_path, "# Sync User Secret\nPrivate to sync-user")

    # Poll until sync-user's note is on server
    api_sync.wait_for_note(sync_path)

    # isolation-user should NOT see it via API
    note_c = api_iso.get_note(sync_path)
    assert note_c is None, "isolation-user should NOT see sync-user's note"

    # isolation-user (C) pulls — file should NOT appear
    await cdp_c.trigger_full_sync()
    assert not (vault_c / sync_path).exists(), "Isolation breach: C got sync-user's note!"

    # --- isolation-user creates a note ---
    iso_path = "E2E/IsoUserSecret.md"
    write_note(vault_c, iso_path, "# Iso User Secret\nPrivate to iso-user")

    # Poll until iso-user's note is on server
    api_iso.wait_for_note(iso_path)

    # sync-user should NOT see it
    note_sync = api_sync.get_note(iso_path)
    assert note_sync is None, "sync-user should NOT see iso-user's note"

    # A pulls — should NOT get iso-user's note
    await cdp_a.trigger_full_sync()
    assert not (vault_a / iso_path).exists(), "Isolation breach: A got iso-user's note!"
