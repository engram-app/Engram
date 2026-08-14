"""Test 91: accepting the sync gate pulls what it held, with no manual sync.

`markSyncGateAccepted` used to unblock the engine and re-fire enrollment but
never re-run the catch-up. Rows the closed gate refused just sat there until a
poll or a manual FullSync happened to come along.

That was survivable only while a blocked replay still consumed the feed and a
downstream validator rewound the cursor to rescue it. Now that a blocked replay
correctly BAILS and leaves the cursor alone, nothing else re-serves those rows —
so if accepting the gate does not pull, the vault stays empty and the user has
no signal at all. The fix and the bail depend on each other, which is precisely
why this needs an end-to-end fence rather than two unit tests.

The prod run on 2026-08-14 reached its notes through a FullSync instead, so this
path shipped unproven outside its unit test. This closes that.

The assertion is the ABSENCE of `trigger_full_sync`. Adding one here would make
the test pass against the broken build and prove nothing.
"""

from __future__ import annotations

import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content

NOTE_COUNT = 4

SET_BLOCKED = "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"


@pytest.mark.asyncio
async def test_accepting_the_gate_pulls_without_a_manual_sync(vault_b, cdp_b, api_sync):
    run = uuid.uuid4().hex[:12]
    paths = [f"E2E/GateAccept-{run}/G{i}.md" for i in range(NOTE_COUNT)]

    await cdp_b.accept_sync_gate()
    await cdp_b.trigger_full_sync()

    # Shut the gate, then publish. These rows are now held: a replay fired by the
    # channel join will bail without consuming them.
    await cdp_b.evaluate(SET_BLOCKED.format("true"))
    gate_open = False
    try:
        for i, path in enumerate(paths):
            api_sync.create_note(path, f"# G{i}\ngate-marker-{i}\n")

        # Prove they really are held, so a pass below cannot be "they arrived
        # early on their own".
        for path in paths:
            assert not (vault_b / path).exists(), (
                f"{path} landed while the gate was closed — the gate is not a gate"
            )

        # The whole test: accepting the gate, and NOTHING else, must drain them.
        await cdp_b.accept_sync_gate()
        gate_open = True

        for i, path in enumerate(paths):
            wait_for_content(
                vault_b, path, f"gate-marker-{i}", timeout=DELIVERY_TIMEOUT
            )
    finally:
        if not gate_open:
            await cdp_b.evaluate(SET_BLOCKED.format("false"))
        for path in paths:
            try:
                api_sync.delete_note(path)
            except Exception:  # noqa: BLE001 - teardown must not mask the failure
                pass
