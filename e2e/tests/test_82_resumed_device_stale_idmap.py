"""Test 82: RESUMED device (cursor set, stale/empty noteIdMap) still syncs live.

Regression for plugin #180→#187 (stale noteIdMap broke BOTH directions while
status showed "live"). Every other e2e device boots fresh (genesis pull →
fully populated map); this is the one test that constructs the resumed state:
stop a device, wipe its persisted noteIds while keeping its syncCursor, then
restart and prove both pull and push still work.

Both phases below edit a note that already exists (seeded in Phase 1, known
to the server, then FORGOTTEN by the wipe) rather than create a brand-new
note. A brand-new note's id<->path pairing is conveyed directly by the CRDT
enrollment/join handshake regardless of noteIdMap state, so it does not
exercise the bug (verified: both a pre-#187 and a #187+ plugin pass a
new-note pull). The actual crux — per docs/context/noteidmap-stale-breaks-sync.md
— is resolving the id of a note the device already knew and then forgot.

KNOWN LIMITATION (bite-check): running this exact scenario against a plugin
build predating #187 (dfc40db~1, commit 7e73d95) still PASSES in this local
harness — traced noteIdMap.toJSON() against GET /sync/manifest at each
checkpoint and confirmed B's in-memory map is already fully and CORRECTLY
repopulated (matching the server's real ids) within a few seconds of
restart, even without reconcileNoteIdMapFromManifest existing in that build.
Some other mechanism in this harness (client catch-up pull on reconnect,
and/or backend /sync/changes semantics) re-teaches ids faster/more broadly
here than the original prod incident implies, so this test currently proves
the BEHAVIOR (resumed device with a wiped map + preserved cursor still syncs
both directions) rather than discriminating pre/post #187. Left as a
regression guard for that behavior; see task-A2-report.md for the full
investigation (churn-note variant, in-memory map dumps, routing-log traces).
"""

import pytest

from helpers.vault import wait_for_content, write_note

pytestmark = pytest.mark.asyncio


async def test_resumed_device_with_stale_idmap_syncs_both_ways(
    fresh_instance_pair, api_sync
):
    inst_a, inst_b, cdp_a, cdp_b = fresh_instance_pair

    # Phase 1: normal sync so B earns a cursor + populated map, and learns the
    # ids of two pre-existing notes (one per direction we'll test post-resume).
    write_note(inst_a.vault_path, "E2E/Resumed-pull-seed.md", "# PullSeed\noriginal")
    write_note(inst_a.vault_path, "E2E/Resumed-push-seed.md", "# PushSeed\noriginal")
    wait_for_content(inst_b.vault_path, "E2E/Resumed-pull-seed.md", "original", timeout=30)
    wait_for_content(inst_b.vault_path, "E2E/Resumed-push-seed.md", "original", timeout=30)

    # Phase 2: flush B's state, stop it, wipe the id map but KEEP the cursor.
    await cdp_b.persist_plugin_data()
    inst_b.stop()

    def wipe_map(data):
        assert data.get("syncCursor"), "precondition: cursor must be set"
        data["noteIds"] = {}

    inst_b.mutate_data_json(wipe_map)
    await inst_b.async_start(restart=True)

    # Phase 3a: PULL direction — A edits the PRE-EXISTING pull-seed note (its
    # id is exactly what the wiped map no longer knows); resumed B must
    # live-materialize the edit. Uses wait_for_content (not the delivery
    # oracle) because the path already exists non-empty on B, so the oracle's
    # non-empty guard would return the stale content on the first poll.
    write_note(inst_a.vault_path, "E2E/Resumed-pull-seed.md", "# PullSeed\nedited after B resumed")
    got = wait_for_content(
        inst_b.vault_path, "E2E/Resumed-pull-seed.md", "edited after B resumed", timeout=30
    )
    assert "edited after B resumed" in got

    # Phase 3b: PUSH direction — resumed B edits the PRE-EXISTING push-seed
    # note (its id is exactly what the wiped map no longer knows) and the
    # server must get it.
    write_note(inst_b.vault_path, "E2E/Resumed-push-seed.md", "# PushSeed\nedited on resumed B")
    note = api_sync.wait_for_note_content(
        "E2E/Resumed-push-seed.md", "edited on resumed B", timeout=30
    )
    assert note is not None, "resumed B's push never reached the server"
