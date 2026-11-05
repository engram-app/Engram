"""Plugin bug 2 (Engram-obsidian#673, orig #668): a remote edit is reverted on a
just-created note.

A creates a note; the server stores it but A never sees the ack, so the create
is re-sent after the rejoin. Meanwhile another writer (the API, standing in for
MCP/web) edits the stored note. The re-sent create finds the row occupied.
The old plugin diffed disk (the create body) onto the server doc two-way, which
reads the remote edit as something disk deleted and removes it everywhere. The
fix keeps the body the create sent (`ownGenesis`) and merges three-way
(`mergeOwnCreateDrift`), so disk == what we sent means: keep the server's text.

Stage: on A, drop every inbound frame (the create reply and fan-out never
arrive) while the create goes out, wait until the server holds the body, apply
the remote edit through the API, then restore inbound and close the socket so
the plugin rejoins and replays the create. Branch covered: disk still equals the body the create sent, so the
replay takes the base === disk branch (keep the server text, `ownGenesis` or
the acked baseline as base), not `mergeOwnCreateDrift` (disk != base), which
the plugin unit tests pin. A disk edit during the window was left out: it
would race the flush of the remote edit onto A.

The oracle is note content on the
server, A and B only; no client-log needle (the plugin log diet raised the
remote log level).

Fails on plugin 1.39.1 and older: the replayed create diffs two-way and the
remote edit vanishes from the server, A and B (the assertion on the marker).
Passes on plugin main (09dc2cd, PR 673).
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from helpers.cdp import PLUGIN_PATH
from helpers.latency import DELIVERY_TIMEOUT

# TODO: dedupe with the swallow-frames helper in test/e2e-unacked-redeliver
# (PR 2435) once it is on main; not coupled here.
from helpers.vault import wait_for_content, write_note

CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound, not a latency assert
MARKER = "REMOTE-EDIT-ON-FRESH-NOTE"
# The only reach into plugin privates: the channel's inbound frame handler.
_STREAM = f"{PLUGIN_PATH}.noteStream"
_RECONNECTED = f"(() => {{ const w = {_STREAM}.ws; return !!w && w !== window.__oldWs && w.readyState === 1; }})()"


# Create-ack evidence: the engine records this head only when the server acks.
def _acked_expr(path: str) -> str:
    return f"({PLUGIN_PATH}.syncEngine.getCrdtHead({json.dumps(path)}) === '__crdt_created__')"


async def _drop_inbound(cdp) -> None:
    await cdp.evaluate(
        f"(() => {{ {_STREAM}.handleMessage = () => {{}}; return 'ok'; }})()"
    )


async def _restore_inbound(cdp) -> None:
    # Drops the instance override; the prototype handler takes over again.
    await cdp.evaluate(f"(() => {{ delete {_STREAM}.handleMessage; return 'ok'; }})()")


@pytest.mark.asyncio
async def test_remote_edit_survives_replayed_create_of_own_new_note(
    vault_a, vault_b, cdp_a, api_sync
):
    path = "E2E/Crdt/OwnCreateMerge.md"
    body = "# Own Create\ncreated on A.\n"
    await cdp_a.wait_for_stream_connected()

    await _drop_inbound(cdp_a)
    try:
        write_note(vault_a, path, body)
        # The create reached the server (only its reply is lost).
        api_sync.wait_for_note_content(path, "created on A", timeout=CRDT_TIMEOUT)
        status = api_sync.append_note(path, f"{MARKER}\n")
        assert status == 200, f"remote edit rejected: {status}"
        api_sync.wait_for_note_content(path, MARKER, timeout=CRDT_TIMEOUT)
    finally:
        await _restore_inbound(cdp_a)

    # Socket dies; the plugin rejoins and replays the unacked create, which now
    # lands on a row holding body + remote edit.
    await cdp_a.evaluate(
        f"(() => {{ window.__oldWs = {_STREAM}.ws; {_STREAM}.ws?.close(); return 'closed'; }})()"
    )

    # A REAL reconnect (a new, open socket), then the replayed create acked:
    # the head flips to the created sentinel only on the create's ack, and the
    # reply was dropped, so it cannot be set by the first send.
    deadline = time.monotonic() + CRDT_TIMEOUT
    while not await cdp_a.evaluate(_RECONNECTED):
        assert time.monotonic() < deadline, "plugin never opened a new socket"
        await asyncio.sleep(0.5)
    while not await cdp_a.evaluate(_acked_expr(path)):
        assert time.monotonic() < deadline, "replayed create never acked on A"
        await asyncio.sleep(0.5)
    await cdp_a.wait_for_crdt_queue_drain(timeout=CRDT_TIMEOUT)

    # Settled: every copy must hold body and edit. B got the marker by fan-out
    # alone, so A and the server are the verdict; B must still agree.
    for vault in (vault_a, vault_b):
        final = wait_for_content(vault, path, MARKER, timeout=CRDT_TIMEOUT)
        assert "created on A" in final, f"own body lost: {final!r}"
    server = api_sync.get_note(path)["content"]
    assert MARKER in server and "created on A" in server, (
        f"server lost an edit: {server!r}"
    )
