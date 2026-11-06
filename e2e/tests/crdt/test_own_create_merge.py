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
the plugin rejoins and replays the create.

The disk-lag race is FAKED: `flushFromCrdt`, the sole writer of remote text to
disk, is a no-op from just before the remote edit until the replayed create
has adopted, then one flush of the doc's
projection lands it. In the real race the edit reaches the doc but not yet the
disk; without the hook the rejoin catch-up flushes the marker to A's disk first, the
old plugin's two-way diff of disk onto the doc is then a no-op, and the test
cannot go red. Branch covered: disk still equals the body the create sent, so
the replay takes the base === disk branch (keep the server text, `ownGenesis`
or the acked baseline as base), not `mergeOwnCreateDrift` (disk != base),
which the plugin unit tests pin.

The oracle is note content on the server, A and B only; no client-log needle
(the plugin log diet raised the remote log level).

Expected: red on the pre-fix plugin (1.39.1, commit 307b121a), where the
replayed create diffs two-way and drops the remote edit; green on plugin main (fix is
PR 673). Proof is CI runs pinned to each plugin, not this file.
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
MARKER = "REMOTE-EDIT-ON-FRESH-NOTE"
# The only reach into plugin privates: the channel, the engine, the op queue.
# (Not the swallow-frames helper of test_unacked_redeliver.py: that drops
# outbound `ws.send`; this drops inbound frames, so nothing is shared.)
_STREAM = f"{PLUGIN_PATH}.noteStream"
_ENGINE = f"{PLUGIN_PATH}.syncEngine"
_QUEUE = f"{PLUGIN_PATH}.crdtOpQueue"
_RECONNECTED = (
    f"(() => {{ const w = {_STREAM}.ws;"
    " return !!w && w !== window.__oldWs && w.readyState === 1; })()"
)


async def _js(cdp, body: str, **kw):
    return await cdp.evaluate(f"(() => {{ {body} return 'ok'; }})()", **kw)


async def _count_create_enqueues(cdp, path: str) -> None:
    """Count creates enqueued for `path` from now on (a fast enqueue+ack
    between polls still registers; a queue snapshot alone can miss it)."""
    await _js(
        cdp,
        f"const q = {_QUEUE}; window.__createEnq = 0;"
        " const orig = q.enqueue.bind(q);"
        " q.enqueue = (op) => {"
        " if (op.kind === 'create' &&"
        f" (op.path ?? op.payload?.path) === {json.dumps(path)})"
        " window.__createEnq++;"
        " return orig(op); };",
    )


async def _hold_disk(cdp) -> None:
    """Fake the disk-lag window: remote text is not written to disk."""
    await _js(cdp, f"{_ENGINE}.flushFromCrdt = async () => true;")


async def _flush_doc_to_disk(cdp, path: str, note_id: str) -> None:
    """The delayed disk write finally landing: write what the doc now holds.

    The hook swallowed the plugin's own flushes (including the replay's), and
    nothing else re-flushes an unchanged doc, so A's disk would stay body-only
    on every plugin. Writing the doc's projection is the honest end of the
    faked lag: the marker reaches disk iff the doc kept it.
    """
    await cdp.evaluate(
        f"(async () => {{ const e = {_ENGINE};"
        f" await e.flushFromCrdt({json.dumps(path)},"
        f" await e.crdt.projectedText({json.dumps(note_id)})); return 'ok'; }})()",
        await_promise=True,
    )


async def _restore_plugin(cdp) -> None:
    """Undo every instance override and probe; idempotent."""
    await _js(
        cdp,
        f"delete {_STREAM}.handleMessage; delete {_ENGINE}.flushFromCrdt;"
        f" delete {_QUEUE}.enqueue;"
        " delete window.__oldWs; delete window.__createEnq;",
    )


@pytest.mark.asyncio
async def test_remote_edit_survives_replayed_create_of_own_new_note(
    vault_a, vault_b, cdp_a, api_sync
):
    path = "E2E/Crdt/OwnCreateMerge.md"
    body = "# Own Create\ncreated on A.\n"
    await cdp_a.wait_for_stream_connected()

    # One try/finally from before the first override, so a failure anywhere
    # restores the handler, the flush hook and the queue wrapper.
    try:
        await _count_create_enqueues(cdp_a, path)
        await _js(cdp_a, f"{_STREAM}.handleMessage = () => {{}};")  # drop inbound
        write_note(vault_a, path, body)
        # The create reached the server (only its reply is lost).
        api_sync.wait_for_note_content(path, "created on A", timeout=CRDT_TIMEOUT)
        await _hold_disk(cdp_a)
        status = api_sync.append_note(path, f"{MARKER}\n")
        assert status == 200, f"remote edit rejected: {status}"
        api_sync.wait_for_note_content(path, MARKER, timeout=CRDT_TIMEOUT)

        # Inbound back, then the socket dies: the plugin rejoins and replays
        # the unacked create onto a row holding body + remote edit. The counter
        # restarts at the close, so only a create enqueued AFTER it counts.
        await _js(cdp_a, f"delete {_STREAM}.handleMessage;")
        await _js(
            cdp_a,
            f"window.__oldWs = {_STREAM}.ws; window.__createEnq = 0;"
            f" {_STREAM}.ws?.close();",
        )

        # A REAL reconnect (a new, open socket), a post-close create enqueued,
        # and no create for this path still queued: the replay was acked.
        deadline = time.monotonic() + CRDT_TIMEOUT
        while True:
            ops = await cdp_a.get_crdt_queue_ops()
            queued = any(o["kind"] == "create" and o["path"] == path for o in ops)
            enqueued = await cdp_a.evaluate("window.__createEnq > 0")
            reconnected = await cdp_a.evaluate(_RECONNECTED)
            if reconnected and enqueued and not queued:
                break
            assert time.monotonic() < deadline, (
                f"replay not seen: reconnected={reconnected} "
                f"enqueued={enqueued} queued={queued}"
            )
            await asyncio.sleep(0.2)
        await cdp_a.wait_for_crdt_queue_drain(timeout=CRDT_TIMEOUT)
        # Land the delayed disk flush of whatever the doc now holds.
        await _js(cdp_a, f"delete {_ENGINE}.flushFromCrdt;")
        note_id = await cdp_a.wait_for_note_id_for_path(path, timeout=CRDT_TIMEOUT)
        await _flush_doc_to_disk(cdp_a, path, note_id)
    finally:
        await _restore_plugin(cdp_a)

    # Settled: every copy must hold body and edit. B got the marker by fan-out
    # alone, so A and the server are the verdict; B must still agree.
    for vault in (vault_a, vault_b):
        final = wait_for_content(vault, path, MARKER, timeout=CRDT_TIMEOUT)
        assert "created on A" in final, f"own body lost: {final!r}"
    server = api_sync.get_note(path)["content"]
    assert MARKER in server and "created on A" in server, (
        f"server lost an edit: {server!r}"
    )
