"""CRDT drift self-heal (rc.3 rename-orphan regression).

Reproduces the production bug where a device loses a note's id->path mapping
mid-session (the "drift" that a rename or a diverged local id can cause). Once
that happens, inbound CRDT content for the note's id can no longer resolve a
disk path, so `onFlushToDisk` strands it ("no known path") and the note goes
laggy / duplicates. The map must re-resolve the id from the server manifest
when a strand is detected, instead of stranding forever.

The rc.3 once-per-session reconcile only repairs the map on the first connect,
so a mid-session drift never self-heals. This test drives that exact state.
"""

from __future__ import annotations

import asyncio
import json
import os

import pytest

from helpers.vault import wait_for_content, write_note

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = 30
DRIFT_ATTEMPTS = 5
DRIFT_HOLD_S = 1.0
PLUGIN = "app.plugins.plugins['engram-vault-sync']"


@pytest.mark.asyncio
async def test_drifted_map_self_heals_on_inbound_edit(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    path = "E2E/Crdt/Drift.md"

    # Shared CRDT base on both devices.
    write_note(vault_a, path, "# Drift\nbase.\n")
    api_sync.wait_for_note_content(path, "base", timeout=CRDT_TIMEOUT)
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base", timeout=CRDT_TIMEOUT)

    # Drift: B loses the id->path mapping for this note (the diverged state).
    note_id = await cdp_b.evaluate(f"{PLUGIN}.noteIdMap.get({json.dumps(path)})")
    assert note_id, "B should have mapped the note before drift"
    # Delete and read back in ONE synchronous evaluate. As two round-trips, a
    # late index/pull `set()` from the base sync could re-learn the mapping in
    # between, i.e. the self-heal fired before the drift was ever observed.
    inject = (
        f"(() => {{ const m = {PLUGIN}.noteIdMap; m.delete({json.dumps(path)}); "
        f"return m.pathForId({json.dumps(note_id)}); }})()"
    )
    still_drifted = f"{PLUGIN}.noteIdMap.pathForId({json.dumps(note_id)}) === null"
    # The same late `set()` can also land after the injection and before A's
    # edit, which heals the map without the code under test and passes vacuously.
    # So the drift must hold for a full second before the edit goes out.
    for _ in range(DRIFT_ATTEMPTS):
        after = await cdp_b.evaluate(inject)
        assert after is None, "drift injection should have removed the reverse mapping"
        await asyncio.sleep(DRIFT_HOLD_S)
        if await cdp_b.evaluate(still_drifted):
            break
    else:
        pytest.fail(f"B kept re-learning the mapping; drift never held {DRIFT_HOLD_S}s")

    # A edits over CRDT. B must re-resolve id->path and materialize the edit,
    # not strand it forever.
    write_note(vault_a, path, "# Drift\nbase.\nEDIT-AFTER-DRIFT\n")
    final = wait_for_content(vault_b, path, "EDIT-AFTER-DRIFT", timeout=CRDT_TIMEOUT)
    # No duplication: the base line survives exactly once.
    assert final.count("base.") == 1, f"content duplicated on B: {final!r}"
