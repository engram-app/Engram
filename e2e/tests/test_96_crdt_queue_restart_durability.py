"""Test 96: the CRDT op queue survives a client restart and flushes afterwards.

The `#1315` restart-durability box, and the one the unit suite structurally
cannot cover: it can prove `persistable()`/`load()` round-trip a list, but not
that a real Obsidian process wrote that list to `data.json` before dying and
picked it back up on boot.

An op enqueued while the socket is down lives ONLY in this queue. If the write
to `data.json` does not happen, or the load does not, the edit is gone with no
error anywhere. That is the data-loss surface.

Uses instance B and `async_start(restart=True)`, following test_82.
"""

import asyncio

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_crdt_queue_survives_client_restart(obsidian_b, cdp_b, api_sync):
    """Queue an op offline, kill the client, restart, and the op still reaches the server."""
    path = "E2E/CrdtQueueRestart96.md"

    write_note(obsidian_b.vault_path, "E2E/CrdtQueueRestart96base.md", "# base")
    api_sync.wait_for_note("E2E/CrdtQueueRestart96base.md")

    await cdp_b.disconnect_stream()
    assert not await cdp_b.check_stream_connected(), (
        "disconnect_stream() must actually drop the channel"
    )

    write_note(obsidian_b.vault_path, path, "# Restart 96\nqueued before the kill")

    deadline = asyncio.get_event_loop().time() + 20
    ops = []
    while asyncio.get_event_loop().time() < deadline:
        ops = await cdp_b.get_crdt_queue_ops()
        if ops:
            break
        await asyncio.sleep(0.5)
    assert ops, "precondition: the offline write must be held in the CRDT queue"
    queued_ids = {o["docId"] for o in ops}

    # The persist is debounced, so give it room to land BEFORE the kill. This
    # wait is the test being fair to the implementation, not padding: killing
    # inside the debounce window tests the debounce, not durability.
    await asyncio.sleep(3)

    obsidian_b.stop()

    # The durability proof itself, read straight off disk with the client dead.
    data = obsidian_b.read_data_json()
    persisted = data.get("crdtOpQueue") or []
    assert persisted, (
        f"crdtOpQueue must be persisted to data.json before the client dies, got keys={list(data)}"
    )
    # Pin it to THIS test's op. Asserting only that the key is non-empty would
    # pass on any leftover entry and prove nothing about the write we just made.
    persisted_ids = {op.get("docId") for op in persisted}
    assert queued_ids & persisted_ids, (
        f"the op held in memory ({queued_ids}) must be the one on disk ({persisted_ids})"
    )

    await obsidian_b.async_start(restart=True)

    # Restored, rejoined, flushed. No manual nudge: rejoin is what drains it.
    await cdp_b.wait_for_crdt_queue_drain(timeout=60)
    api_sync.wait_for_note(path, timeout=30)
