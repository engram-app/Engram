"""Test 31: Offline queue survives Obsidian restart.

Queue entries are persisted to data.json. After a hard restart, the plugin
should restore the queue and flush it during the startup sync.

WARNING: This test kills and restarts Obsidian instance A. Under xdist
--dist=loadfile it runs last within its worker (intra-file order is
preserved), which is all we need — the restart only affects this
worker's A instance.
"""

import asyncio
import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_restart_preserves_queue(vault_a, cdp_a, api_sync, obsidian_a):
    """Queue entries persist across Obsidian restart and flush on startup."""
    path1 = "E2E/RestartQueue1.md"
    path2 = "E2E/RestartQueue2.md"

    # 1. Simulate offline on A
    await cdp_a.simulate_offline()
    await asyncio.sleep(0.3)

    # 2. Create 2 files → push fails → queued
    write_note(vault_a, path1, "# Restart Queue 1\nSurvives restart")
    time.sleep(0.3)
    write_note(vault_a, path2, "# Restart Queue 2\nAlso survives restart")

    # Wait for EACH path to appear in the queue. Same pattern as test_29:
    # under xdist load, a count-based 10s poll can miss the last write.
    paths_set = {path1, path2}
    deadline = time.monotonic() + 30
    queued_paths: set[str] = set()

    while time.monotonic() < deadline:
        entries = await cdp_a.get_queue_entries()
        queued_paths = {e["path"] for e in entries}
        if paths_set.issubset(queued_paths):
            break
        await asyncio.sleep(0.5)

    missing = paths_set - queued_paths
    assert not missing, (
        f"Expected both paths queued within 30s. Missing: {sorted(missing)}. "
        f"Queued entries: {await cdp_a.get_queue_entries()}"
    )

    # 3. Force persist queue to data.json (bypass debounce)
    await cdp_a.persist_plugin_data()

    # 4. Kill Obsidian A (hard stop — simulates crash)
    obsidian_a.stop()
    await asyncio.sleep(0.3)

    # 5. Restart Obsidian A (restart=True preserves vault + data.json with queue)
    await obsidian_a.async_start(restart=True)
    await cdp_a.wait_for_plugin_ready(timeout=60)

    # 6. Startup sync should restore queue and flush it.
    #    Poll instead of hard sleep — returns as soon as notes arrive.
    #    Same xdist race class as PR #39: the cycle of plugin-ready →
    #    SyncEngine.startupSync → queue.replay → push can exceed 15s under
    #    2-worker load. Match the queue-wait deadline (30s) on both.
    note1 = api_sync.wait_for_note(path1, timeout=30)
    note2 = api_sync.wait_for_note(path2, timeout=30)

    # 7. Both notes should now be on server
    assert note1 is not None, f"{path1} should be on server after restart"
    assert note2 is not None, f"{path2} should be on server after restart"
    assert "Survives restart" in note1["content"]
    assert "Also survives restart" in note2["content"]
