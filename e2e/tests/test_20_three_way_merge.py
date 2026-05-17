"""Test 20: Three-way merge auto-resolves non-overlapping edits.

A and B both edit the same note but in different sections. When B pulls,
the 3-way merge (base → local diff + base → remote diff) detects
non-overlapping edit ranges and merges both changes cleanly — no conflict
dialog, no conflict file.

Requires v0.6.0+ (BaseStore + threeWayMerge in SyncEngine).
"""

import pytest

from helpers.vault import read_note, write_note


BASE_CONTENT = """\
# Three Way Merge Test

## Section A
Original content in section A.

## Section B
Original content in section B.

## Section C
Original content in section C.
"""


@pytest.mark.asyncio
async def test_three_way_merge_clean(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Non-overlapping edits from A and B are auto-merged."""
    path = "E2E/ThreeWayMerge.md"

    # 1. A creates base note with 3 distinct sections
    write_note(vault_a, path, BASE_CONTENT)
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls — establishes synced state + populates baseStore
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note"

    # 3. A edits Section A only → pushes to server
    a_version = BASE_CONTENT.replace(
        "Original content in section A.",
        "Edited by A in section A.",
    )
    write_note(vault_a, path, a_version)
    api_sync.wait_for_note_content(path, "Edited by A", timeout=10)

    # 4. Pause B's outgoing sync so B's edit stays local-only
    await cdp_b.pause_outgoing_sync()

    # 5. B edits Section C only (non-overlapping with A's edit)
    b_version = BASE_CONTENT.replace(
        "Original content in section C.",
        "Edited by B in section C.",
    )
    write_note(vault_b, path, b_version)

    # 6. B pulls — 3-way merge should combine both edits cleanly
    await cdp_b.trigger_pull()

    # 7. Verify B's file has BOTH edits
    b_content = read_note(vault_b, path)
    assert "Edited by A in section A." in b_content, (
        f"Missing A's edit in merged content: {b_content[:300]}"
    )
    assert "Edited by B in section C." in b_content, (
        f"Missing B's edit in merged content: {b_content[:300]}"
    )
    # Section B should be untouched
    assert "Original content in section B." in b_content, (
        f"Section B was unexpectedly modified: {b_content[:300]}"
    )

    # 8. Resume outgoing sync (clean shutdown — no further pushes expected).
    await cdp_b.resume_outgoing_sync()

    # 9. Verify server has the merged content. The plugin's three-way merge
    #    path force-pushes the merged result inside applyChange (sync.ts
    #    pushFile(existing, true)), so no manual sync is required.
    api_sync.wait_for_note_content(path, "Edited by A in section A.", timeout=10)
    api_sync.wait_for_note_content(path, "Edited by B in section C.", timeout=10)
