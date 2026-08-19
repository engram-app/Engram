"""Test 96: the CRDT op queue is persisted to disk, so a hard kill cannot lose it.

The `#1315` durability box. An op enqueued while the socket is down lives only
in `CrdtOpQueue` until it flushes; if it never reaches `data.json`, a crash
loses a path->id claim with no error anywhere. The unit suite can prove
`persistable()`/`load()` round-trip a list, but not that the real plugin writes
that list to disk.

Scope, deliberately narrowed after two CI failures. This test used to stop the
client and restart it. Two problems with that:

* It bought nothing. Vault B still has the file on disk, so a plain boot re-push
  satisfies "the note reached the server" just as well as a queue replay would.
  Isolating those needs a way to suppress the boot push, which does not exist.
  The on-disk assertion was always the load-bearing one.
* It cost a lot. `stop()` is `pkill -9` plus an `rmtree` of the config dir, and
  the restart respawns Xvfb and Obsidian. `obsidian_b` is SESSION-scoped and
  test_82 already restarts it, so this added a SECOND full restart cycle to one
  session. Both CI failures landed in test_82's restart afterwards: once
  `Xvfb failed to start (rc=-9)`, once `CDP not available after 60s`. Classic
  resource pressure, and this test was the new contributor.

So it now proves persistence and stops there, with the process left running.
The reload half stays open on #1315 and wants harness support to be worth
having.
"""

import asyncio

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_crdt_queue_is_persisted_to_disk(obsidian_b, cdp_b, api_sync):
    """An op queued while offline is written to data.json, where a crash cannot lose it."""
    path = "E2E/CrdtQueueRestart96.md"

    write_note(obsidian_b.vault_path, "E2E/CrdtQueueRestart96base.md", "# base")
    api_sync.wait_for_note("E2E/CrdtQueueRestart96base.md")

    await cdp_b.disconnect_stream()

    # `obsidian_b` is SESSION-scoped: an assertion failing while its socket is
    # down would leave every later test talking to a dead channel.
    try:
        assert not await cdp_b.check_stream_connected(), (
            "disconnect_stream() must actually drop the channel"
        )

        write_note(obsidian_b.vault_path, path, "# Restart 96\nqueued while offline")

        deadline = asyncio.get_event_loop().time() + 20
        queued_ids: set = set()
        ops: list = []
        while asyncio.get_event_loop().time() < deadline:
            ops = await cdp_b.get_crdt_queue_ops()
            queued_ids = {o["docId"] for o in ops if o.get("path") == path}
            if queued_ids:
                break
            await asyncio.sleep(0.5)
        assert queued_ids, f"precondition: the offline write must be held, queue={ops}"

        # Drive the plugin's OWN savePluginData. Persist is debounced, so without
        # this the read below races the write and fails for the wrong reason.
        await cdp_b.persist_plugin_data()

        # The durability proof: the op is on disk, pinned to THIS test's op.
        # Asserting the key is merely non-empty would pass on any leftover entry.
        data = obsidian_b.read_data_json()
        persisted = data.get("crdtOpQueue") or []
        persisted_ids = {op.get("docId") for op in persisted}
        assert queued_ids & persisted_ids, (
            f"the op held in memory ({queued_ids}) must be on disk; "
            f"data.json had {persisted_ids} (keys={list(data)})"
        )
    finally:
        await cdp_b.reconnect_stream()

    # And it still converges once the socket returns.
    await cdp_b.wait_for_crdt_queue_drain(timeout=45)
    api_sync.wait_for_note(path, timeout=30)
