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
the test falls back to a short bounded wait, and nothing re-sends the
swallowed frame: the server and B stay on the base text until timeout, which
is the failing assertion (not a missing probe). Passes on plugin main
(09dc2cd, PR 673).
"""

from __future__ import annotations

import asyncio
import time

import pytest

from helpers.cdp import PLUGIN_PATH
from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content, write_note

CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound, not a latency assert
MARKER = "EDIT-ON-HALF-DEAD-SOCKET"
# Fallback unacked window when the plugin has no probe (<= 1.39.1). Kept far
# below the ~30-60s after which a swallowed heartbeat makes the plugin close
# the socket by itself; an early rejoin there would still be tolerated, the
# convergence assertions below do not care who closed the socket.
FALLBACK_WINDOW = 5
# The only reach into plugin privates: the live socket and the CRDT registry.
_WS = f"{PLUGIN_PATH}.noteStream.ws"
_UNACKED = (
    f"(() => {{ const c = {PLUGIN_PATH}.syncEngine.crdt;"
    " return typeof c?.unackedDocIds === 'function' ? c.unackedDocIds() : null; })()"
)


async def _unacked(cdp) -> list[str] | None:
    """Unacked resident doc ids, or None when this plugin has no probe."""
    return await cdp.evaluate(_UNACKED)


async def _swallow_sends(cdp) -> None:
    await cdp.evaluate(f"(() => {{ {_WS}.send = () => {{}}; return 'ok'; }})()")


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
    while (unacked := await _unacked(cdp_a)) is not None and note_id in unacked:
        assert time.monotonic() < deadline, f"base never acked on A: {unacked!r}"
        await asyncio.sleep(0.5)
    supported = unacked is not None

    await _swallow_sends(cdp_a)
    try:
        write_note(vault_a, path, base + f"{MARKER}\n")

        if supported:
            deadline = time.monotonic() + CRDT_TIMEOUT
            while note_id not in (unacked := await _unacked(cdp_a) or []):
                assert time.monotonic() < deadline, (
                    f"edit never became an unacked doc on A (unacked={unacked!r}); "
                    "the edit did not take the live crdt_msg path"
                )
                await asyncio.sleep(0.5)
        else:
            await asyncio.sleep(FALLBACK_WINDOW)

        # The frame really was lost: the server still lacks the edit.
        assert MARKER not in str(api_sync.get_note(path)), (
            "server already has the edit; the socket was not black-holed"
        )

        # Socket dies; the plugin reconnects and rejoins, which must re-send.
        await cdp_a.evaluate(f"(() => {{ {_WS}.close(); return 'closed'; }})()")
    finally:
        await _restore_sends(cdp_a)

    api_sync.wait_for_note_content(path, MARKER, timeout=CRDT_TIMEOUT)
    final = wait_for_content(vault_b, path, MARKER, timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base lost on B: {final!r}"
