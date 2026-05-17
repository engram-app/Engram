"""Test 22: Worst-case conflict → modal receives correct data, all resolutions work.

Both sides heavily rewrite the same sections of a multi-section note.
The 3-way merge detects overlapping ranges and falls through to the modal
conflict handler. We verify that ConflictInfo contains the correct
baseContent, localContent, and remoteContent, and that each resolution
choice (merge, keep-local, keep-remote) produces the expected outcome.

Requires v0.6.0+ (BaseStore + threeWayMerge in SyncEngine).
"""

import json

import pytest

from helpers.vault import read_note, write_note

ENGINE = "app.plugins.plugins['engram-vault-sync'].syncEngine"


BASE_CONTENT = """\
# Worst Case Conflict

## Introduction
This is the original introduction written by the author.

## Details
Original details that both sides will rewrite entirely.

## Conclusion
The original conclusion of this document.
"""


async def setup_worst_case(
    path: str,
    vault_a,
    vault_b,
    cdp_b,
    api_sync,
    *,
    a_content: str,
    b_content: str,
):
    """Create a worst-case conflict: both sides rewrite overlapping sections.

    After this function returns:
    - Server has A's version
    - B has B's version locally (outgoing sync paused)
    - B's baseStore has the original base content (from initial sync)
    """
    # 1. A creates the base note
    write_note(vault_a, path, BASE_CONTENT)
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls — establishes syncState + populates baseStore with BASE_CONTENT
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note"

    # 3. A rewrites the note → pushes to server
    write_note(vault_a, path, a_content)
    api_sync.wait_for_note_content(path, "Rewritten by A", timeout=10)

    # 4. Pause B's outgoing sync
    await cdp_b.pause_outgoing_sync()

    # 5. B rewrites the same sections locally
    write_note(vault_b, path, b_content)


A_CONTENT = """\
# Worst Case Conflict

## Introduction
Rewritten by A — completely new intro with different structure.
Added extra context that wasn't there before.

## Details
Rewritten by A — replaced all original details with A's analysis.

## Conclusion
Rewritten by A — new conclusion that contradicts the original.
"""

B_CONTENT = """\
# Worst Case Conflict

## Introduction
Rewritten by B — a totally different take on the introduction.
B added their own perspective here.

## Details
Rewritten by B — B's analysis is completely different from A's.

## Conclusion
Rewritten by B — B's conclusion goes in a different direction.
"""


@pytest.mark.asyncio
async def test_conflict_modal_receives_base_content(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Modal handler receives baseContent, localContent, and remoteContent."""
    path = "E2E/WorstCaseModal.md"

    await setup_worst_case(
        path, vault_a, vault_b, cdp_b, api_sync,
        a_content=A_CONTENT, b_content=B_CONTENT,
    )

    try:
        # Switch to modal mode and install a handler that captures ConflictInfo
        await cdp_b.set_conflict_resolution("modal")
        await cdp_b.evaluate(f"""
            (function() {{
                const se = {ENGINE};
                se._capturedConflict = null;
                se.onConflict = async (info) => {{
                    se._capturedConflict = {{
                        path: info.path,
                        hasBase: info.baseContent != null,
                        baseLen: info.baseContent ? info.baseContent.length : 0,
                        localLen: info.localContent.length,
                        remoteLen: info.remoteContent.length,
                        baseSnippet: info.baseContent ? info.baseContent.substring(0, 80) : null,
                        localSnippet: info.localContent.substring(0, 80),
                        remoteSnippet: info.remoteContent.substring(0, 80),
                    }};
                    return {{ choice: 'keep-local' }};
                }};
                return 'handler installed';
            }})()
        """)

        # B pulls — 3-way merge fails (overlapping edits) → modal handler called
        await cdp_b.trigger_pull()

        # Read back the captured ConflictInfo
        captured = await cdp_b.evaluate(
            f"JSON.stringify({ENGINE}._capturedConflict)",
        )
        info = json.loads(captured)

        assert info is not None, "Conflict handler was never called"
        assert info["path"] == path
        assert info["hasBase"] is True, "baseContent should be present from initial sync"
        assert info["baseLen"] > 0, "baseContent should have content"
        assert "original" in info["baseSnippet"].lower(), (
            f"baseContent should be the original version, got: {info['baseSnippet']}"
        )
        assert "Rewritten by B" in info["localSnippet"], (
            f"localContent should be B's version, got: {info['localSnippet']}"
        )
        assert "Rewritten by A" in info["remoteSnippet"], (
            f"remoteContent should be A's version, got: {info['remoteSnippet']}"
        )
    finally:
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")
        await cdp_b.resume_outgoing_sync()


@pytest.mark.asyncio
async def test_conflict_modal_merge_resolution(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Modal merge resolution applies merged content and pushes to server."""
    path = "E2E/WorstCaseMerge.md"
    merged = "# Worst Case Conflict\n\nManually merged from both A and B."

    await setup_worst_case(
        path, vault_a, vault_b, cdp_b, api_sync,
        a_content=A_CONTENT, b_content=B_CONTENT,
    )

    try:
        # Modal mode with merge handler
        await cdp_b.set_conflict_resolution("modal")
        await cdp_b.override_conflict_handler("merge", merged_content=merged)
        await cdp_b.resume_outgoing_sync()

        # B pulls — conflict → merge resolution
        await cdp_b.trigger_pull()

        # B should have the merged content
        b_content = read_note(vault_b, path)
        assert "Manually merged from both A and B" in b_content, (
            f"Expected merged content, got: {b_content[:200]}"
        )

        # Server should have the merged content — applyChange's merge branch
        # force-pushes (sync.ts pushFile(existing, true)).
        api_sync.wait_for_note_content(path, "Manually merged from both A and B", timeout=10)
    finally:
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")


@pytest.mark.asyncio
async def test_conflict_modal_keep_remote_overwrites_local(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Keep-remote replaces local content with server version."""
    path = "E2E/WorstCaseKeepRemote.md"

    await setup_worst_case(
        path, vault_a, vault_b, cdp_b, api_sync,
        a_content=A_CONTENT, b_content=B_CONTENT,
    )

    try:
        await cdp_b.set_conflict_resolution("modal")
        await cdp_b.override_conflict_handler("keep-remote")

        # B pulls — conflict → keep-remote
        await cdp_b.trigger_pull()

        # B's file should now have A's (remote) content
        b_content = read_note(vault_b, path)
        assert "Rewritten by A" in b_content, (
            f"Expected A's remote content after keep-remote, got: {b_content[:200]}"
        )
        assert "Rewritten by B" not in b_content, (
            "B's local content should be gone after keep-remote"
        )
    finally:
        await cdp_b.restore_conflict_handler()
        await cdp_b.set_conflict_resolution("auto")
        await cdp_b.resume_outgoing_sync()
