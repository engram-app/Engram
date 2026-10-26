"""Gauntlet 6: a note whose first crdt_create was lost, opened before the retry.

A sim-fuzz finding the sim could not prove (it stands in for the CodeMirror
binding). Device B creates a note while idle. Its FIRST `crdt_create` never
reaches the server (dropped, rejected after the real 10 s request timeout,
exactly what a lost push looks like to the caller), so the create is queued
for durable retry. B then OPENS the note in the editor, binding it live, and
only after that is the held retry let out.

Suspected outcome: the server and device A get an EMPTY note while B keeps
the body and believes it synced. Asserted: server == B's disk == A's disk,
body included, no conflict copy; and that the retry really was a crdt_create.
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid

import pytest

from helpers.convergence import Expect, await_converged
from helpers.gauntlet import creates_seen, hook_creates, release_creates, unhook_creates

logger = logging.getLogger(__name__)


@pytest.mark.timeout(600)
async def test_lost_first_create_then_open_before_retry(gauntlet):
    pair = await gauntlet("glost")
    b = pair.b
    root = f"LostCreate-{uuid.uuid4().hex[:6]}"
    path = f"{root}/fresh.md"

    await b.cdp.wait_for_stream_connected()
    await hook_creates(b.cdp, ["drop"], rest="hold")
    try:
        await b.cdp.vault_write(path, f"# Fresh\n\nbody-{root}\n")
        end = time.monotonic() + 30
        while not (await creates_seen(b.cdp)):
            assert time.monotonic() < end, "first crdt_create never sent"
            await asyncio.sleep(0.5)
        await asyncio.sleep(11)  # past the dropped request's 10 s timeout
        assert await b.cdp.open_note_in_live_preview(path) == path
        await asyncio.sleep(3)  # let the editor bind before the retry goes out
        await release_creates(b.cdp)
        await asyncio.sleep(5)
    finally:
        calls = await unhook_creates(b.cdp)
    logger.warning("GAUNTLET lost-create: crdt_create calls on B %s", calls)
    # The scenario only holds if the durable retry really was a crdt_create.
    assert calls and calls[0]["path"] == path, calls
    assert len(calls) >= 2, f"no crdt_create retry at all: {calls}"

    try:
        await await_converged(pair.api, pair.vaults, root, Expect({path: [f"body-{root}"]}), deadline_s=180)
    except AssertionError as e:
        server = pair.api.get_note(path)
        raise AssertionError(
            f"{e}\ncrdt_create calls on B: {calls}\nserver content: {server and server.get('content')!r}"
        ) from None
