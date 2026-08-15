"""Test 89: a closed sync gate HOLDS the catch-up feed, it does not consume it.

Prod, 2026-08-13. A first sync into an empty vault created every folder and
zero notes, then reported success and 100% downloaded. Two defects stacked:

  1. `flushFromCrdt` returned true while the gate was shut, having written
     nothing. The replay counted those phantom writes as downloaded files, so
     the progress bar filled, the recap said "success", and the
     produced-nothing anomaly could not fire.
  2. `walkOpLog` persisted the catch-up cursor per page regardless. A blocked
     walk therefore advanced the cursor PAST every row it had refused to
     write, and the next catch-up resumed after them. The notes were not
     delayed, they were skipped.

Only #1 is visible from inside the plugin's own suite, and that suite was
fully green the entire time the bug was in production. This test pins the
loop end to end against a real Obsidian and a real backend, which is the
layer the bug actually survived.

The cursor assertion is the load-bearing one. "No files on disk while
blocked" is also true of the broken build, so on its own it proves nothing;
what separates fixed from broken is whether the feed rows are still there to
serve once the gate opens.
"""

from __future__ import annotations

import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content

NOTE_COUNT = 5

SET_BLOCKED = "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"
GET_CURSOR = "app.plugins.plugins['engram-vault-sync'].syncEngine.getCatchupSeq()"


@pytest.mark.asyncio
async def test_closed_gate_holds_the_feed_until_it_opens(vault_b, cdp_b, api_sync):
    # Run-unique paths. Fixtures are session-scoped and vault notes survive
    # between runs, so a fixed path would already be on disk when this test
    # starts and the "nothing was written" assertion would fail for the wrong
    # reason. Deleted again in the finally below so the folder doesn't grow.
    run = uuid.uuid4().hex[:12]
    paths = [f"E2E/GateHold-{run}/Held{i}.md" for i in range(NOTE_COUNT)]

    # Drain anything already pending so the cursor we snapshot is quiet. Without
    # this, an unrelated row landing mid-test moves the cursor and the "did not
    # advance" assertion reads as a failure of this code path when it isn't.
    await cdp_b.trigger_full_sync()
    cursor_before = await cdp_b.evaluate(GET_CURSOR)

    await cdp_b.evaluate(SET_BLOCKED.format("true"))
    try:
        for i, path in enumerate(paths):
            api_sync.create_note(path, f"# Held {i}\nheld-marker-{i}\n")

        # A full sync against a closed gate. The engine is allowed to do
        # nothing; what it may NOT do is consume the rows while doing nothing.
        await cdp_b.trigger_full_sync()

        for path in paths:
            assert not (vault_b / path).exists(), (
                f"{path} was written with the sync gate closed — the gate is not a gate"
            )

        cursor_after = await cdp_b.evaluate(GET_CURSOR)
        assert cursor_after == cursor_before, (
            f"catch-up cursor moved {cursor_before} -> {cursor_after} while blocked. "
            f"Those {NOTE_COUNT} rows are now behind the cursor and will never be "
            f"served again — this is the 2026-08-13 data-loss shape."
        )
    finally:
        await cdp_b.evaluate(SET_BLOCKED.format("false"))

    # Gate open: every held row must still be there to serve.
    try:
        await cdp_b.trigger_full_sync()
        for i, path in enumerate(paths):
            wait_for_content(
                vault_b, path, f"held-marker-{i}", timeout=DELIVERY_TIMEOUT
            )
    finally:
        # Best-effort only: teardown must never mask the real assertion error.
        for path in paths:
            try:
                api_sync.delete_note(path)
            except Exception:  # noqa: BLE001 - teardown, see above
                pass
