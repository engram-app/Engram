"""Gauntlet 6: a note whose first crdt_create was lost, opened before the retry.

The plugin sim fuzz flagged this as probable but could not prove it, because
the sim stands in for the CodeMirror binding. Real Obsidian settles it.

Device B creates a note while idle. Its FIRST `crdt_create` never reaches the
server (dropped in the channel and rejected after the real 10 s request
timeout, exactly what a lost push looks like to the caller), so the create is
queued for durable retry. B then OPENS the note in the editor, binding it
live, and only after that is the retry allowed out.

Suspected outcome: the server and device A get an EMPTY note while B keeps
the body and believes it synced. Asserted: server == B's disk == A's disk,
body included, no conflict copy.
"""

from __future__ import annotations

import asyncio
import json
import logging
import time
import uuid

import pytest

from helpers.cdp import PLUGIN_PATH
from helpers.convergence import Expect, await_converged

logger = logging.getLogger(__name__)

# Drops the first crdt_create (rejects after the request's own timeout, never
# sends it) and holds every later one until window.__e2eReleaseCreates is set.
# Records each crdt_create the channel was asked for, so a failure can say
# whether the retry used crdt_create at all.
_ARM = f"""(() => {{
    const ch = {PLUGIN_PATH}.noteStream;
    const orig = ch.sendRequest.bind(ch);
    window.__e2eCreates = [];
    window.__e2eReleaseCreates = false;
    ch.__e2eOrigSendRequest = orig;
    ch.sendRequest = (event, payload, timeoutMs = 10000) => {{
        if (event !== 'crdt_create') return orig(event, payload, timeoutMs);
        const n = window.__e2eCreates.push({{path: payload.path, hasBody: payload.b64 !== undefined, at: Date.now()}});
        if (n === 1) {{
            return new Promise((_, reject) => setTimeout(() => {{
                window.__e2eFirstCreateRejected = true;
                reject(new Error('sendRequest timeout: crdt_create'));
            }}, timeoutMs));
        }}
        return (async () => {{
            while (!window.__e2eReleaseCreates) await new Promise(r => setTimeout(r, 100));
            return orig(event, payload, timeoutMs);
        }})();
    }};
    return 'armed';
}})()"""

_DISARM = f"""(() => {{
    const ch = {PLUGIN_PATH}.noteStream;
    if (ch.__e2eOrigSendRequest) {{ ch.sendRequest = ch.__e2eOrigSendRequest; delete ch.__e2eOrigSendRequest; }}
    return JSON.stringify(window.__e2eCreates || []);
}})()"""


@pytest.mark.timeout(600)
async def test_lost_first_create_then_open_before_retry(gauntlet):
    pair = await gauntlet("glost")
    b = pair.b
    root = f"LostCreate-{uuid.uuid4().hex[:6]}"
    path = f"{root}/fresh.md"
    body = f"# Fresh\n\nbody-{root}\n"

    await b.cdp.wait_for_stream_connected()
    assert await b.cdp.evaluate(_ARM) == "armed"
    creates = "[]"
    try:
        await b.cdp.vault_write(path, body)
        end = time.monotonic() + 30
        while not await b.cdp.evaluate("!!window.__e2eFirstCreateRejected"):
            assert time.monotonic() < end, f"first crdt_create never sent: {await b.cdp.evaluate('JSON.stringify(window.__e2eCreates)')}"
            await asyncio.sleep(0.5)

        opened = await b.cdp.open_note_in_live_preview(path)
        assert opened == path, opened
        await asyncio.sleep(3)  # let the editor bind before the retry goes out
        opened_at = await b.cdp.evaluate("window.__e2eOpenedAt = Date.now()")
        await b.cdp.evaluate("window.__e2eReleaseCreates = true")
        await asyncio.sleep(5)
    finally:
        creates = await b.cdp.evaluate(_DISARM)
    logger.warning("GAUNTLET lost-create: crdt_create calls on B %s", creates)
    calls = json.loads(creates)
    # The scenario only holds if the durable retry really was a crdt_create
    # (held by the hook until after the editor bound); otherwise this proves
    # a different path. Each call's time vs the open is in the message.
    assert calls and calls[0]["path"] == path, calls
    assert len(calls) >= 2, f"no crdt_create retry at all: {calls}"
    retry_vs_open = [c["at"] - opened_at for c in calls[1:]]

    try:
        await await_converged(pair.api, pair.vaults, root, Expect({path: [f"body-{root}"]}), deadline_s=180)
    except AssertionError as e:
        server = pair.api.get_note(path)
        raise AssertionError(
            f"{e}\ncrdt_create calls on B: {calls} (retry ms after open: {retry_vs_open})\n"
            f"server content: {server and server.get('content')!r}\n"
            f"B disk: {(b.vault / path).read_text() if (b.vault / path).exists() else None!r}"
        ) from None
