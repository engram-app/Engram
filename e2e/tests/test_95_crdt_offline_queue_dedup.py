"""Test 95: repeated offline writes to one path collapse to a single queued op.

The `#1315` dedup box. `CrdtOpQueue` coalesces per docId ("one pending op per
docId, newest supersedes older"), which is what stops a long offline spell from
turning N edits to one note into N outbound ops. The unit suite asserts that
about the data structure; this asserts it about a real client whose vault events
are firing for real.

The failure this guards is not a crash. It is a queue that grows one entry per
keystroke-batch and then floods the socket on reconnect.
"""

import asyncio

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_repeated_offline_writes_coalesce(vault_a, cdp_a, api_sync):
    """Several offline writes to ONE path leave one pending op, and the latest content wins."""
    path = "E2E/CrdtQueueDedup95.md"

    write_note(vault_a, "E2E/CrdtQueueDedup95base.md", "# base")
    api_sync.wait_for_note("E2E/CrdtQueueDedup95base.md")

    await cdp_a.disconnect_stream()
    assert not await cdp_a.check_stream_connected(), (
        "disconnect_stream() must actually drop the channel"
    )

    try:
        for i in range(1, 5):
            write_note(vault_a, path, f"# Dedup 95\nrevision {i}")
            await asyncio.sleep(0.4)

        # Wait until the path is represented at all, then assert the SHAPE.
        deadline = asyncio.get_event_loop().time() + 20
        ops = []
        while asyncio.get_event_loop().time() < deadline:
            ops = await cdp_a.get_crdt_queue_ops()
            if ops:
                break
            await asyncio.sleep(0.5)

        assert ops, "expected at least one held op after four offline writes"

        # The invariant: one pending op per docId. Four writes to one path must
        # not produce four entries for that docId.
        per_doc = {}
        for op in ops:
            per_doc[op["docId"]] = per_doc.get(op["docId"], 0) + 1
        worst = max(per_doc.values())
        assert worst == 1, (
            f"queue must hold at most one pending op per docId, got {per_doc} from {ops}"
        )
    finally:
        await cdp_a.reconnect_stream()

    await cdp_a.wait_for_crdt_queue_drain(timeout=45)

    # Newest supersedes older: the surviving op must carry the LAST revision,
    # not the first. A coalesce that kept the oldest would still satisfy the
    # count assertion above while silently losing three revisions.
    api_sync.wait_for_note(path, timeout=30)
    api_sync.wait_for_note_content(path, "revision 4")
