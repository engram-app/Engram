"""Test 19: Multi-tenant WRITE isolation — users cannot modify or delete each other's data.

Test 08 proves READ isolation (user A can't see user C's data).
This test proves WRITE isolation across all mutation endpoints: user C cannot
modify, overwrite, rename, append to, or delete user A's notes or attachments,
even with valid credentials for a different account.

Migrated to API-only: seeds data via api_sync.create_note() instead of Obsidian
vault writes, so these 11 tests run during the Obsidian boot gap in CI.
"""

import time

import pytest


# ---------------------------------------------------------------------------
# Note mutation isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_cannot_modify_other_user_note(api_sync, api_iso):
    """User C (isolation-user) cannot overwrite user A's note via POST /notes."""
    path = "E2E/WriteIsolationTarget.md"
    original_content = "# Write Isolation\nThis belongs to sync-user."

    # sync-user creates a note via API
    api_sync.create_note(path, original_content)
    api_sync.wait_for_note(path, timeout=10)

    # isolation-user attempts to overwrite it via API
    api_iso.create_note(path, "# Hijacked\nOverwritten by isolation-user.")

    # sync-user's note should be unchanged
    note = api_sync.get_note(path)
    assert note is not None, "sync-user's note disappeared"
    assert "This belongs to sync-user" in note["content"], (
        "sync-user's note was modified by another user"
    )

    # isolation-user's create_note should have created their OWN copy
    iso_note = api_iso.get_note(path)
    if iso_note is not None:
        assert "Hijacked" in iso_note["content"]


@pytest.mark.asyncio
async def test_write_isolation_cannot_delete_other_user_note(api_sync, api_iso):
    """User C (isolation-user) cannot delete user A's note."""
    path = "E2E/WriteIsolationDeleteTarget.md"

    api_sync.create_note(path, "# Protected\nThis should survive deletion attempts.")
    api_sync.wait_for_note(path, timeout=10)

    # isolation-user attempts to delete sync-user's note
    status = api_iso.delete_note(path)
    assert status in (200, 404), f"Unexpected status {status} for cross-user delete"

    # sync-user's note must still exist
    note = api_sync.get_note(path)
    assert note is not None, (
        "SECURITY BREACH: isolation-user deleted sync-user's note!"
    )
    assert "This should survive" in note["content"]


@pytest.mark.asyncio
async def test_write_isolation_changes_endpoint(api_sync, api_iso):
    """User C should not see user A's changes in GET /notes/changes."""
    path = "E2E/WriteIsolationChanges.md"

    api_sync.create_note(path, "# Changes Test\nOnly sync-user should see this.")
    api_sync.wait_for_note(path, timeout=10)

    since = "2000-01-01T00:00:00Z"
    changes = api_iso.get_changes(since)
    iso_paths = [n.get("source_path", "") for n in changes.get("notes", [])]
    assert path not in iso_paths, (
        f"SECURITY BREACH: isolation-user can see sync-user's changes! "
        f"Found {path} in changes response."
    )


# ---------------------------------------------------------------------------
# Rename isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_cannot_rename_other_user_note(api_sync, api_iso):
    """User C cannot rename user A's note via POST /notes/rename."""
    path = "E2E/WriteIsolationRenameTarget.md"
    renamed_path = "E2E/Hijacked-Rename.md"

    api_sync.create_note(path, "# Rename Target\nThis should not be renamed by others.")
    api_sync.wait_for_note(path, timeout=10)

    # isolation-user attempts to rename sync-user's note
    status = api_iso.rename_note(path, renamed_path)
    # Should 404 (note doesn't exist for this user) or succeed on their own data only
    assert status in (200, 404), f"Unexpected status {status} for cross-user rename"

    # sync-user's note must still exist at original path
    note = api_sync.get_note(path)
    assert note is not None, (
        "SECURITY BREACH: isolation-user renamed sync-user's note!"
    )
    assert "should not be renamed" in note["content"]

    # The renamed path should NOT exist for sync-user
    renamed_note = api_sync.get_note(renamed_path)
    assert renamed_note is None, (
        "SECURITY BREACH: isolation-user created a note in sync-user's namespace via rename!"
    )


# ---------------------------------------------------------------------------
# Append isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_cannot_append_to_other_user_note(api_sync, api_iso):
    """User C cannot append to user A's note via POST /notes/append."""
    path = "E2E/WriteIsolationAppendTarget.md"
    original = "# Append Target\nOriginal content only."

    api_sync.create_note(path, original)
    api_sync.wait_for_note(path, timeout=10)

    # isolation-user attempts to append to sync-user's note
    status = api_iso.append_note(path, "\n\nINJECTED BY ATTACKER")

    # sync-user's note must be unchanged
    note = api_sync.get_note(path)
    assert note is not None, "sync-user's note disappeared"
    assert "INJECTED BY ATTACKER" not in note["content"], (
        "SECURITY BREACH: isolation-user appended to sync-user's note!"
    )
    assert "Original content only" in note["content"]


# ---------------------------------------------------------------------------
# Attachment isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_cannot_read_other_user_attachment(api_sync, api_iso):
    """User C cannot read user A's attachment via GET /attachments/{path}."""
    att_path = "E2E/secret-image.png"
    fake_png = b"\x89PNG\r\n\x1a\n" + b"\x00" * 100  # minimal PNG-like header

    # sync-user uploads an attachment
    status = api_sync.upload_attachment(att_path, fake_png)
    assert status in (200, 201), f"sync-user upload failed with {status}"

    # isolation-user attempts to read it
    resp = api_iso.get_attachment(att_path)
    assert resp.status_code in (404, 403), (
        f"SECURITY BREACH: isolation-user read sync-user's attachment! "
        f"Status: {resp.status_code}"
    )


@pytest.mark.asyncio
async def test_write_isolation_cannot_delete_other_user_attachment(api_sync, api_iso):
    """User C cannot delete user A's attachment via DELETE /attachments/{path}."""
    att_path = "E2E/protected-file.pdf"
    fake_pdf = b"%PDF-1.4 " + b"\x00" * 100

    # sync-user uploads an attachment
    status = api_sync.upload_attachment(att_path, fake_pdf)
    assert status in (200, 201), f"sync-user upload failed with {status}"

    # isolation-user attempts to delete it
    del_status = api_iso.delete_attachment(att_path)
    assert del_status in (200, 404), f"Unexpected status {del_status}"

    # sync-user's attachment must still be readable
    resp = api_sync.get_attachment(att_path)
    assert resp.status_code == 200, (
        "SECURITY BREACH: isolation-user deleted sync-user's attachment!"
    )


# ---------------------------------------------------------------------------
# Folder rename isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_cannot_rename_other_user_folder(api_sync, api_iso):
    """User C cannot rename user A's folder via POST /folders/rename."""
    path = "E2E/IsoFolder/FolderRenameTarget.md"
    api_sync.create_note(path, "# Folder Target\nInside a folder owned by sync-user.")
    api_sync.wait_for_note(path, timeout=10)

    # isolation-user attempts to rename sync-user's folder
    status = api_iso.rename_folder("E2E/IsoFolder", "E2E/HijackedFolder")

    # sync-user's note must still be at the original folder path
    note = api_sync.get_note(path)
    assert note is not None, (
        "SECURITY BREACH: isolation-user renamed sync-user's folder!"
    )
    assert "owned by sync-user" in note["content"]

    # The hijacked folder path should NOT contain sync-user's note
    hijacked = api_sync.get_note("E2E/HijackedFolder/FolderRenameTarget.md")
    assert hijacked is None, (
        "SECURITY BREACH: isolation-user moved sync-user's notes to a new folder!"
    )


# ---------------------------------------------------------------------------
# Sync manifest isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_manifest_does_not_leak(api_sync, api_iso):
    """User C's sync manifest should not include user A's notes or attachments."""
    path = "E2E/ManifestIsolation.md"
    api_sync.create_note(path, "# Manifest Test\nShould not appear in other manifest.")
    api_sync.wait_for_note(path, timeout=10)

    # sync-user's manifest should include the note
    sync_manifest = api_sync.get_manifest()
    sync_paths = [n["path"] for n in sync_manifest.get("notes", [])]
    assert path in sync_paths, "sync-user's manifest missing their own note"

    # isolation-user's manifest should NOT include it
    iso_manifest = api_iso.get_manifest()
    iso_paths = [n["path"] for n in iso_manifest.get("notes", [])]
    assert path not in iso_paths, (
        f"SECURITY BREACH: isolation-user's manifest contains sync-user's note! "
        f"Found {path} in manifest."
    )


# ---------------------------------------------------------------------------
# Log isolation
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_write_isolation_logs_do_not_leak(api_sync, api_iso):
    """User C cannot see user A's log entries via GET /logs."""
    # sync-user ingests a log entry with a unique marker
    marker = "SYNC_USER_SECRET_LOG_MARKER_42"
    api_sync.ingest_logs([{
        "ts": "2026-03-29T00:00:00Z",
        "level": "info",
        "category": "test",
        "message": marker,
    }])

    # sync-user can see their own logs
    sync_logs = api_sync.get_logs()
    sync_messages = [e.get("message", "") for e in sync_logs.get("logs", [])]
    assert marker in sync_messages, "sync-user can't see their own log entry"

    # isolation-user should NOT see sync-user's log entry
    iso_logs = api_iso.get_logs()
    iso_messages = [e.get("message", "") for e in iso_logs.get("logs", [])]
    assert marker not in iso_messages, (
        f"SECURITY BREACH: isolation-user can see sync-user's log entries! "
        f"Found '{marker}' in logs response."
    )
