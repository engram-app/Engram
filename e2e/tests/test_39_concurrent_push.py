"""Test 39: A and B push different notes simultaneously — both succeed.

Verifies no data loss when two devices sync different files concurrently.
Uses asyncio.gather to trigger parallel syncs.
"""

import asyncio

import pytest

from helpers.vault import wait_for_file, write_note


@pytest.mark.asyncio
async def test_concurrent_push_different_notes(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A and B create different notes simultaneously — server gets both."""
    path_a = "E2E/ConcurrentA39.md"
    path_b = "E2E/ConcurrentB39.md"

    # Both write to their own vaults
    write_note(vault_a, path_a, "# From A\nConcurrent push test.")
    write_note(vault_b, path_b, "# From B\nConcurrent push test.")

    # Trigger both syncs concurrently
    await asyncio.gather(
        cdp_a.trigger_full_sync(),
        cdp_b.trigger_full_sync(),
    )

    # Both notes should be on server WITH content. Genesis now flows through
    # crdt_create_batch: the batch reply confirms the row exists, but the note's
    # body is applied to the CRDT room and persisted to the notes.content column
    # by the room's async eager checkpoint (~250 ms later), not synchronously
    # with the reply. A single read at t=0 races that checkpoint (reads the bare
    # genesis row, content ""), so poll for content convergence instead. This
    # asserts the same invariant — the server holds each note's content — with a
    # bound that spans the checkpoint window.
    note_a = api_sync.wait_for_note_content(path_a, "From A")
    note_b = api_sync.wait_for_note_content(path_b, "From B")
    assert "From A" in note_a["content"], "Server should have A's note"
    assert "From B" in note_b["content"], "Server should have B's note"

    # After another sync round, both vaults should have both notes
    await asyncio.gather(
        cdp_a.trigger_full_sync(),
        cdp_b.trigger_full_sync(),
    )

    wait_for_file(vault_a, path_b)
    wait_for_file(vault_b, path_a)
