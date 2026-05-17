"""Test 25: Concurrent server edit causes 409 on push.

A creates a note and syncs. Then the API client updates the note directly
on the server (simulating another device), incrementing the version. When A
edits the note locally and pushes, the server returns 409 (version conflict).
The plugin should handle this via 3-way merge or conflict resolution.
"""

import asyncio
import time

import pytest

from helpers.vault import read_note, write_note


@pytest.mark.asyncio
async def test_push_409_handled(vault_a, cdp_a, api_sync):
    """Push gets 409 from concurrent server edit — plugin handles gracefully."""
    path = "E2E/Push409.md"
    base_content = "# Push 409 Test\n\nSection A: original\n\nSection B: original"

    # 1. A creates note → push to server (establishes version N)
    write_note(vault_a, path, base_content)
    api_sync.wait_for_note(path, timeout=10)

    # Wait for A to finish syncing (sync state established)
    await cdp_a.trigger_full_sync()

    # 2. API client updates note directly (version now N+1)
    #    Edit Section B only — non-overlapping with A's upcoming edit
    server_content = "# Push 409 Test\n\nSection A: original\n\nSection B: edited by server"
    api_sync.create_note(path, server_content, mtime=time.time())

    # 3. A edits Section A locally → push → should get 409
    local_content = "# Push 409 Test\n\nSection A: edited by A\n\nSection B: original"
    write_note(vault_a, path, local_content)

    # Wait for push attempt + conflict resolution
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        a_content = read_note(vault_a, path)
        if "edited by A" in a_content:
            break
        await asyncio.sleep(0.5)

    # 4. Verify: the note should be in a consistent state
    #    Either auto-merged (both edits) or conflict-resolved
    a_content = read_note(vault_a, path)
    server_note = api_sync.get_note(path)

    assert server_note is not None, "Server should still have the note"

    # The 409 handler must produce one of these outcomes — anything else is data loss:
    # a) Auto-merge succeeded: both edits present in A's local file
    # b) Conflict file created: A's local edit preserved, conflict copy exists
    # c) Keep-local: A's edit preserved locally
    # In ALL cases, A's local edit must survive.
    assert "edited by A" in a_content, (
        f"A's local edit was lost during 409 handling! Got: {a_content[:300]}"
    )

    auto_merged = "edited by server" in a_content
    if auto_merged:
        # Three-way merge inside applyChange force-pushes (sync.ts
        # pushFile(existing, true)), so both edits should land on the
        # server without any manual touch.
        api_sync.wait_for_note_content(path, "edited by A", timeout=10)
        api_sync.wait_for_note_content(path, "edited by server", timeout=10)
    else:
        # Auto-merge didn't fire — check for conflict file (auto resolution)
        e2e_dir = vault_a / "E2E"
        conflict_files = list(e2e_dir.glob("Push409 (conflict*).md"))
        # Server's edit should be either in the conflict file or on the server
        server_content = server_note.get("content", "")
        has_server_edit = (
            "edited by server" in server_content
            or any("edited by server" in f.read_text() for f in conflict_files)
        )
        assert has_server_edit, (
            f"Server's edit was lost during 409 handling! "
            f"Server content: {server_content[:200]}, "
            f"Conflict files: {[f.name for f in conflict_files]}"
        )
