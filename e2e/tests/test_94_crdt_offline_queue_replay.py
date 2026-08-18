"""Test 94: CRDT outbound op queue holds work across a socket drop and replays it.

Re-establishes the durability coverage #775 deleted with test_24/28/29/31. Those
drove the REST push path, which is retired; this drives the CRDT path.

The mechanism under test is `CrdtOpQueue` (plugin `src/crdt-op-queue.ts`), NOT
the REST `OfflineQueue`. They are separate, and the old `simulate_offline()`
helper cannot exercise this one: it stubs `api.*` methods, while CRDT traffic
rides the WebSocket. Hence `disconnect_stream()` / `reconnect_stream()`.

Why it matters: an edit made while the socket is down lives only in this queue
until it flushes. Its dedup/ordering/bounding is unit-tested against the data
structure; what has had no coverage since #775 is that the invariant survives a
real client against a real backend.
"""

import asyncio

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_crdt_offline_queue_replays_on_reconnect(vault_a, cdp_a, api_sync):
    """Notes created while the CRDT socket is down reach the server after it returns."""
    path1 = "E2E/CrdtQueue94a.md"
    path2 = "E2E/CrdtQueue94b.md"

    # Establish a healthy baseline first. Creating offline from a cold start
    # would also exercise first-sync, which is a different (and separately
    # tested) path — this test is about the drop, not the bootstrap.
    write_note(vault_a, "E2E/CrdtQueue94base.md", "# base")
    api_sync.wait_for_note("E2E/CrdtQueue94base.md")

    await cdp_a.disconnect_stream()
    # The queue only HOLDS while the channel is not joined, so the assertions
    # below are meaningless if the drop did not take.
    assert not await cdp_a.check_stream_connected(), (
        "disconnect_stream() must actually drop the channel"
    )

    try:
        write_note(vault_a, path1, "# Queued 1\nwritten while the socket was down")
        await asyncio.sleep(0.3)
        write_note(vault_a, path2, "# Queued 2\nalso written while down")

        # Enqueue is a REACTION to the vault event, so poll rather than
        # snapshotting a point in time (the #635 lesson from the old test_24).
        deadline = asyncio.get_event_loop().time() + 20
        ops = []
        while asyncio.get_event_loop().time() < deadline:
            ops = await cdp_a.get_crdt_queue_ops()
            if len({o["docId"] for o in ops}) >= 2:
                break
            await asyncio.sleep(0.5)

        assert len({o["docId"] for o in ops}) >= 2, (
            f"expected both offline creates held in the CRDT queue, got {ops}"
        )
    finally:
        # MUST restore even if an assertion fails, or every later test in the
        # session inherits a dead socket.
        await cdp_a.reconnect_stream()

    await cdp_a.wait_for_crdt_queue_drain(timeout=45)

    api_sync.wait_for_note(path1, timeout=30)
    api_sync.wait_for_note(path2, timeout=30)

    assert await cdp_a.get_crdt_queue_size() == 0, (
        "queue must be empty once both creates are acked"
    )
