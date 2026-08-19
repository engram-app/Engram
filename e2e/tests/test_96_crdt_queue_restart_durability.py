"""Test 96: the CRDT op queue is persisted before a hard kill and reloaded after.

The `#1315` restart-durability box, and the part the unit suite structurally
cannot reach: it can prove `persistable()`/`load()` round-trip a list, but not
that a real Obsidian process wrote that list to `data.json` before being
SIGKILLed, nor that boot picked it back up.

An op enqueued while the socket is down lives only in this queue. If the write
to `data.json` does not happen, or the load does not, the claim is gone with no
error anywhere.

Scope, stated honestly: the load-bearing assertion is the on-disk one, read with
the process dead. The post-restart convergence check below is deliberately NOT
claimed as proof the QUEUE delivered it — vault B still has the file on disk, so
a plain boot re-push would also satisfy it. Isolating those two needs a way to
suppress the boot push, which does not exist today; the on-disk assertion plus
the reload observation is what this test can honestly prove.

Uses instance B and `async_start(restart=True)`, following test_82.
"""

import asyncio

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_crdt_queue_survives_client_restart(obsidian_b, cdp_b, api_sync):
    """Queue an op offline, hard-kill the client, and the op is on disk and reloaded."""
    path = "E2E/CrdtQueueRestart96.md"

    write_note(obsidian_b.vault_path, "E2E/CrdtQueueRestart96base.md", "# base")
    api_sync.wait_for_note("E2E/CrdtQueueRestart96base.md")

    stopped = False
    await cdp_b.disconnect_stream()

    # Everything from here to the restart runs under try/finally. `obsidian_b`
    # is SESSION-scoped: an assertion failing in between would otherwise leave B
    # socket-dead, or (past stop()) fully torn down with its config_dir removed,
    # for every later test in the run. Those tests would then fail with unrelated
    # CDP connection errors and bury the real failure.
    try:
        assert not await cdp_b.check_stream_connected(), (
            "disconnect_stream() must actually drop the channel"
        )

        write_note(obsidian_b.vault_path, path, "# Restart 96\nqueued before the kill")

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

        # Drive the plugin's OWN savePluginData rather than sleeping past the
        # debounce. stop() is a SIGKILL, so a fixed sleep racing a loaded CI box
        # would surface as a confusing "not persisted" assertion instead of a
        # timeout.
        await cdp_b.persist_plugin_data()

        obsidian_b.stop()
        stopped = True

        # The durability proof, read off disk with the process dead. Pinned to
        # THIS test's op: asserting the key is merely non-empty would pass on any
        # leftover entry and prove nothing about the write just made.
        data = obsidian_b.read_data_json()
        persisted = data.get("crdtOpQueue") or []
        persisted_ids = {op.get("docId") for op in persisted}
        assert queued_ids & persisted_ids, (
            f"the op held in memory ({queued_ids}) must be on disk before the kill; "
            f"data.json had {persisted_ids} (keys={list(data)})"
        )
    finally:
        if stopped:
            await obsidian_b.async_start(restart=True)
            # Hand B back in the state the rest of the SESSION expects, not just
            # "running". A restarted instance comes up with its stream not yet
            # re-established and its remote logging not re-seeded, and the
            # delivery oracle reads B's CLIENT LOGS — so the next test that waits
            # on a B-side delivery fails with `received=no materialized=yes`:
            # the file lands, but the evidence never ships. Verified: test_09
            # passes alone and fails immediately after this test without these
            # two lines.
            await cdp_b.enable_remote_logging()
            await cdp_b.wait_for_stream_connected()
        else:
            await cdp_b.reconnect_stream()

    # Reloaded and converged. The drain has no "was ever non-empty" guard on
    # purpose: the queue may legitimately have flushed before the first poll, and
    # the reload itself is already evidenced by the on-disk assertion above.
    await cdp_b.wait_for_crdt_queue_drain(timeout=60)
    api_sync.wait_for_note(path, timeout=30)
