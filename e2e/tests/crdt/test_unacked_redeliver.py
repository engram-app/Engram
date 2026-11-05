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

Fails on plugin 1.39.1 and older: nothing re-sends the swallowed frame, so
the server and B stay on the base text until timeout. Passes on plugin main
(09dc2cd, PR 673).
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.cdp import PLUGIN_PATH
from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content, write_note

CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound, not a latency assert
NS = f"{PLUGIN_PATH}.noteStream"
MARKER = "EDIT-ON-HALF-DEAD-SOCKET"


@pytest.mark.asyncio
async def test_edit_sent_on_half_dead_socket_is_redelivered_after_rejoin(
    vault_a, vault_b, cdp_a, api_sync
):
    path = "E2E/Crdt/UnackedRedeliver.md"
    base = "# Unacked Redeliver\nbase line.\n"

    # Shared base: the note is resident (and acked) on A, present on B.
    write_note(vault_a, path, base)
    api_sync.wait_for_note_content(path, "base line", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)
    note = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = note.get("note", note)
    note_id = str(inner.get("id") or inner.get("note_id") or inner.get("uuid"))
    await cdp_a.wait_for_stream_connected()

    # Half-open: sends are swallowed, readyState stays OPEN.
    await cdp_a.evaluate(f"(() => {{ {NS}.ws.send = () => {{}}; return 'ok'; }})()")

    write_note(vault_a, path, base + f"{MARKER}\n")

    # The plugin sent into the void: the doc is resident and unacked.
    deadline = asyncio.get_event_loop().time() + CRDT_TIMEOUT
    while True:
        unacked = await cdp_a.evaluate(
            f"{PLUGIN_PATH}.syncEngine.crdt?.unackedDocIds?.() ?? []"
        )
        if note_id in unacked:
            break
        assert asyncio.get_event_loop().time() < deadline, (
            f"edit never became an unacked doc on A (unacked={unacked!r}); "
            "the edit did not take the live crdt_msg path"
        )
        await asyncio.sleep(0.5)

    # The server must not have the edit yet (the frame really was lost).
    server = api_sync.get_note(path)
    assert MARKER not in str(server), (
        "server already has the edit; socket was not black-holed"
    )

    # Socket dies; the plugin reconnects and rejoins, which must re-send.
    await cdp_a.evaluate(f"(() => {{ {NS}.ws.close(); return 'closed'; }})()")

    api_sync.wait_for_note_content(path, MARKER, timeout=CRDT_TIMEOUT)
    final = wait_for_content(vault_b, path, MARKER, timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base lost on B: {final!r}"
