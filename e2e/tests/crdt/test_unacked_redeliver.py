"""Plugin bug 5 (Engram-obsidian#673): an edit sent on a half-dead socket is
re-sent after the rejoin.

A live `crdt_msg` has no ack. If the socket is already dead when the debounced
push runs (an iOS resume), the frame vanishes while the echo baseline says
disk is synced: no sweep, catch-up or handshake re-sends it and the edit never
leaves the device. The fix (`redeliverUnackedDocs`, driven by
`ProviderRegistry.unackedDocIds`) re-sends every unacked resident doc on the
next crdt join.

Stage (deterministic, no timing race): on A, swallow every outbound frame
while leaving the socket reading OPEN (half-open: the plugin believes it is
connected), edit a closed, resident note on disk, wait until the plugin
reports the doc unacked, prove the server never got the edit, then close the
socket so the plugin rejoins. The oracle is content on the server and on B
only; no client-log needle (the plugin log-diet raised the remote log level).

Fails on plugin 1.39.1 and older: `unackedDocIds` does not exist there, so
the test skips that probe (the swallowed-frame wait works everywhere), and nothing re-sends the
swallowed frame: the server and B stay on the base text until timeout, which
is the failing assertion (not a missing probe). Passes on plugin main
(09dc2cd, PR 673).
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from helpers.cdp import PLUGIN_PATH
from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content, write_note

CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound, not a latency assert
MARKER = "EDIT-ON-HALF-DEAD-SOCKET"
# The only reach into plugin privates: the live socket and the CRDT registry.
_WS = f"{PLUGIN_PATH}.noteStream.ws"
NO_PROBE = "no-probe"  # plugin predates unackedDocIds (<= 1.39.1)
NOT_READY = "not-ready"  # crdt registry not up yet: wait, never treat as no-probe
_UNACKED = (
    f"(() => {{ const c = {PLUGIN_PATH}.syncEngine.crdt;"
    " if (!c) return 'not-ready';"
    " return typeof c.unackedDocIds === 'function' ? c.unackedDocIds() : 'no-probe'; })()"
)


async def _unacked(cdp) -> list[str] | str:
    """Unacked resident doc ids, NO_PROBE, or NOT_READY."""
    return await cdp.evaluate(_UNACKED)


async def _swallow_sends(cdp) -> None:
    """Drop every outbound frame, recording each one's text in `swallowed`."""
    await cdp.evaluate(
        f"(() => {{ const w = {_WS}; w.swallowed = [];"
        " w.send = (f) => { w.swallowed.push(String(f)); }; return 'ok'; })()"
    )


async def _swallowed_for(cdp, note_id: str) -> int:
    """Frames swallowed so far that carry `note_id` (heartbeats do not)."""
    return await cdp.evaluate(
        f"(() => ({_WS}?.swallowed ?? []).filter("
        f"(f) => f.includes({json.dumps(note_id)})).length)()"
    )


async def _restore_sends(cdp) -> None:
    # Drops the instance override; harmless if the socket was already replaced.
    await cdp.evaluate(f"(() => {{ if ({_WS}) delete {_WS}.send; return 'ok'; }})()")


@pytest.mark.asyncio
async def test_edit_sent_on_half_dead_socket_is_redelivered_after_rejoin(
    vault_a, vault_b, cdp_a, api_sync
):
    path = "E2E/Crdt/UnackedRedeliver.md"
    base = "# Unacked Redeliver\nbase line.\n"

    # Shared base: the note is resident on A and present on B.
    write_note(vault_a, path, base)
    api_sync.wait_for_note_content(path, "base line", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)
    note_id = await cdp_a.wait_for_note_id_for_path(path, timeout=CRDT_TIMEOUT)
    await cdp_a.wait_for_stream_connected()

    # Baseline: the doc must be acked before the edit, so "unacked" later
    # proves the edit's frame was lost (a receipt-less doc also reads unacked).
    deadline = time.monotonic() + CRDT_TIMEOUT
    while True:
        unacked = await _unacked(cdp_a)
        if unacked != NOT_READY and not (
            isinstance(unacked, list) and note_id in unacked
        ):
            break
        assert time.monotonic() < deadline, f"base never acked on A: {unacked!r}"
        await asyncio.sleep(0.5)
    supported = unacked != NO_PROBE

    await _swallow_sends(cdp_a)
    try:
        write_note(vault_a, path, base + f"{MARKER}\n")

        # Close only after the plugin really attempted (and we swallowed) a
        # frame for this doc: the Y.Doc turning unacked alone does not prove
        # the debounced send ran, and closing earlier lets the plain rejoin
        # handshake deliver the edit on a plugin without the fix.
        deadline = time.monotonic() + CRDT_TIMEOUT
        while await _swallowed_for(cdp_a, note_id) < 1:
            assert time.monotonic() < deadline, (
                "plugin never sent a frame for the edited doc on A; "
                "the edit did not take the live crdt_msg path"
            )
            await asyncio.sleep(0.5)
        if supported:
            unacked = await _unacked(cdp_a)
            assert isinstance(unacked, list) and note_id in unacked, unacked

        # The frame really was lost: the server still lacks the edit.
        assert MARKER not in str(api_sync.get_note(path)), (
            "server already has the edit; the socket was not black-holed"
        )

        # Socket dies; the plugin reconnects and rejoins, which must re-send.
        await cdp_a.evaluate(f"(() => {{ {_WS}?.close(); return 'closed'; }})()")
    finally:
        await _restore_sends(cdp_a)

    api_sync.wait_for_note_content(path, MARKER, timeout=CRDT_TIMEOUT)
    final = wait_for_content(vault_b, path, MARKER, timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base lost on B: {final!r}"
