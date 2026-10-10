"""Test 101: first sync of ordinary Obsidian frontmatter must not raise conflicts.

Prod 2026-10-10 (engram-app/Engram#1928): a new user's first sync of a
245-note vault wrote 54 `(conflict ...)` copies and 54 "sync conflict" Notices
with no edit anywhere.

Two defects stack:

1. The genesis apply flushes the plugin's frontmatter PROJECTION over the
   file, then the create-ack stamped the last-synced baseline from the RAW
   pre-create bytes, a baseline no file holds any more.
2. The plugin and the backend emit the same values differently
   (`"[[Home]]"` vs `'[[Home]]'`, `key: null` vs `key:`), so the server row
   differs from disk too.

The next catch-up saw disk != baseline != row and took the "local+remote both
diverged" branch, which writes a conflict copy per note.

test_100 syncs similar shapes but fences only the lineage count and never
looks for NEW files, so it passed through all of this.
"""

from __future__ import annotations

import pytest

from helpers.frontmatter_first_sync import DRIFTING_SHAPES, first_sync_shapes


@pytest.mark.asyncio
async def test_first_sync_frontmatter_raises_no_conflicts(vault_a, cdp_a, api_sync):
    result = await first_sync_shapes(
        vault_a, cdp_a, api_sync, DRIFTING_SHAPES, "FmConflict"
    )
    print(
        f"\ntest_101 conflict-copies={result.conflict_copies} "
        f"| rewritten-on-disk={sorted(result.rewritten)}"
    )
    assert result.conflict_copies == [], (
        f"first sync of untouched notes wrote {len(result.conflict_copies)} "
        f"conflict copies: {result.conflict_copies}. The create-ack baseline "
        "does not match what the genesis apply wrote to disk, so catch-up read "
        "the plugin's own frontmatter rewrite as a local edit "
        "(engram-app/Engram#1928)."
    )
