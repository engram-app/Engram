"""Test 93: a rename received from a peer MOVES B's file, it does not recreate it.

test_10 already covers rename PROPAGATION -- new path present, old path gone --
and that is exactly what made this class of bug invisible for so long. Those
assertions pass perfectly when the receiver deletes the old file and writes a
new one in its place, which is what it was doing: right bytes, brand-new file.
Obsidian treats that as a different note, so the open tab closes, backlinks
re-resolve and the creation date resets.

The discriminator is the INODE. A move preserves it; delete-then-create cannot.
So this asserts the verb rather than the payload -- the one thing the unit
suite cannot check, because only a real filesystem has inodes.

Fixed in plugin PR #441; see plugin docs/context/remote-rename-identity-vs-file.md.
"""

import os
import time
import uuid

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_file_gone, write_note


def _inode(path) -> int:
    return os.stat(path).st_ino


@pytest.mark.asyncio
async def test_remote_rename_moves_the_file(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """B's file must be MOVED to the new path, keeping its identity on disk."""
    # Unique per-run paths: the A/B instances are session-scoped and not reset
    # between reruns, so a fixed path lets a prior attempt's note_id map and
    # sync-state contaminate the next one (same reasoning as test_10).
    suffix = uuid.uuid4().hex[:12]
    old_path = f"E2E/MoveOld-{suffix}.md"
    new_path = f"E2E/MoveNew-{suffix}.md"

    write_note(vault_a, old_path, "# Move Test\nThis file must be moved, not rebuilt.")
    api_sync.wait_for_note(old_path)

    # B receives it live, and we record the identity of the file on B's disk.
    wait_for_delivery(vault_b, old_path, api_sync)
    before = _inode(vault_b / old_path)

    # A renames. B learns about it as a delete + upsert pair.
    await cdp_a.rename_file(old_path, new_path)
    api_sync.wait_for_note(new_path)
    api_sync.wait_for_note_gone(old_path)

    content = wait_for_delivery(vault_b, new_path, api_sync)
    assert "Move Test" in content, "B should have the renamed file"
    wait_for_file_gone(vault_b, old_path)

    # THE ASSERTION. Same inode = the file was moved. A different one means B
    # destroyed the note and built a replacement, which is the regression.
    #
    # Read after wait_for_file_gone so the old path is settled: a receiver that
    # briefly holds both would otherwise be sampled mid-flight and read as a
    # move purely by timing.
    after = _inode(vault_b / new_path)
    assert after == before, (
        f"B recreated the note instead of moving it "
        f"(inode {before} -> {after}). The bytes are correct but the file is new, "
        f"so Obsidian loses the note's identity: open tabs close, backlinks "
        f"re-resolve, creation date resets."
    )

    # And the move must not echo back as a fresh rename from B, which would have
    # the two devices trading renames. Give the echo a chance to land, then
    # confirm the server still agrees with A.
    time.sleep(2)
    api_sync.wait_for_note(new_path)
    api_sync.wait_for_note_gone(old_path)
