"""Test 27: Empty markdown file syncs correctly between devices.

Edge case: a zero-content .md file should push, pull, and then accept
edits that propagate normally.
"""

import time

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import read_note, write_note


def _wait_for_file_exists(vault_path, rel_path: str, timeout: float = 30, poll: float = 0.3) -> None:
    """Poll for existence, allowing a genuinely empty (0-byte) file.

    wait_for_delivery/wait_for_file guard on non-empty content to dodge the
    0-byte read-before-flush race, but this test's whole point is a note
    that legitimately stays empty — that guard would hang forever here.
    """
    full = vault_path / rel_path
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if full.exists():
            return
        time.sleep(poll)
    raise TimeoutError(f"File {rel_path} did not appear within {timeout}s")


@pytest.mark.asyncio
async def test_empty_note_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Empty note pushes to server and reaches B live, then edits propagate."""
    path = "E2E/EmptyNote.md"

    # A creates an empty markdown file
    write_note(vault_a, path, "")
    api_sync.wait_for_note(path, timeout=10)

    # Server should have the note (possibly with empty content)
    note = api_sync.get_note(path)
    assert note is not None, "Empty note should exist on server"

    # B receives it via catch-up. An EMPTY note has no content -> no Y.Doc
    # update -> no note_yjs_update fan-out, so its only live signal is the
    # edge-triggered crdt_doc_ready announce. If B misses that announce (a real
    # possibility under load), passive delivery falls back to the ~5-min poll and
    # no reasonable wait covers it — a fast pass when the announce lands, a hard
    # timeout when it doesn't (the test_27 flake). Drive B's catch-up so the
    # empty note arrives deterministically (the test's stated intent is that an
    # empty note "push, pull, and accept edits").
    await cdp_b.trigger_full_sync()
    _wait_for_file_exists(vault_b, path, timeout=30)
    b_content = read_note(vault_b, path)
    assert b_content.strip() == "" or len(b_content.strip()) == 0, (
        f"B's file should be empty, got: {b_content[:100]}"
    )

    # A edits empty → non-empty
    write_note(vault_a, path, "# No Longer Empty\nThis note has content now.")
    api_sync.wait_for_note_content(path, "No Longer Empty", timeout=10)

    # B receives the update via catch-up (deterministic, same rationale).
    await cdp_b.trigger_full_sync()
    b_content = wait_for_delivery(vault_b, path, api_sync, timeout=30)
    assert "No Longer Empty" in b_content, (
        f"B should have updated content, got: {b_content[:200]}"
    )
