"""Gauntlet 2: an iPhone-like suspend/resume loop converges without a room storm.

Engram#2242: one iPhone opened ~800 heal rooms in 3 minutes. It had been
suspended and resumed repeatedly; each time it woke onto a half-dead socket
with idle notes that had changed elsewhere.

Simulated as closely as the harness allows (no device here runs iOS):

  * Obsidian's own mobile emulation (`app.emulateMobile(true)`): the plugin
    boots with `Platform.isMobile` true and Node modules refused, as on a phone.
  * Suspend = `visibilitychange` to hidden (the plugin flushes and persists),
    then the renderer FROZEN (`Page.setWebLifecycleState`), so no timer,
    heartbeat or socket handler runs, and the link half-open (NetCut
    blackhole: the socket still looks OPEN, nothing gets through).
  * While A sleeps, the server and device B edit notes A holds idle.
  * Wake = unfreeze + visible (fires `noteStream.onResume()`) while the link is
    still dead; A edits idle notes offline long enough for room-free reads
    (10 s each) to time out; then the network comes back.
  * Four cycles back to back, as the storming device did.

NOT covered (Electron is not WKWebView): iOS's own networking stack behind
requestUrl, IndexedDB eviction under memory pressure, the OS killing a
suspended app outright (gauntlet 3 covers a hard kill), and Capacitor
lifecycle events. `Platform.isIosApp` stays false.
"""

from __future__ import annotations

import asyncio
import logging
import random
import time
import uuid

import pytest

from helpers.convergence import Expect, await_converged
from helpers.gauntlet import RoomBudget, api_append_many, append_lines, create_notes
from helpers.room_probe import read_room_starts

logger = logging.getLogger(__name__)

NOTES = 200
CYCLES = 4
SERVER_EDITS_PER_CYCLE = 100  # an uncapped device opens ~1 room each: 400 vs a ~140 budget
B_EDITS_PER_CYCLE = 10
A_OFFLINE_EDITS_PER_CYCLE = 8
SUSPENDED_S = 15
WOKEN_OFFLINE_S = 25  # > two 10 s room-free read timeouts
ONLINE_GAP_S = 10


@pytest.mark.timeout(1200)
async def test_mobile_suspend_resume_cycles_bounded_and_converged(gauntlet):
    pair = gauntlet("gmob")
    a, b = pair.a, pair.b
    await a.cdp.emulate_mobile()
    rng = random.Random(2242)
    root = f"Mobile-{uuid.uuid4().hex[:6]}"

    model = {f"{root}/n-{i:03d}.md": [f"seed-{root}-{i:03d}"] for i in range(NOTES)}
    await create_notes(b.cdp, {p: f"# {p}\n\n{m[0]}\n" for p, m in model.items()})
    await await_converged(pair.api, pair.vaults, root, Expect({p: list(m) for p, m in model.items()}), deadline_s=300)

    budget = RoomBudget("mobile cycles")
    per_cycle = []
    for cycle in range(CYCLES):
        before = read_room_starts()
        paths = sorted(model)
        server_paths = rng.sample(paths, SERVER_EDITS_PER_CYCLE)
        rest = [p for p in paths if p not in server_paths]
        b_paths = rng.sample(rest, B_EDITS_PER_CYCLE)
        # Half of A's offline edits land on notes the server is also changing.
        a_paths = rng.sample(server_paths, A_OFFLINE_EDITS_PER_CYCLE // 2) + rng.sample(
            rest, A_OFFLINE_EDITS_PER_CYCLE // 2
        )

        await a.cdp.suspend()
        a.net.blackhole()
        server = {p: f"srv-{cycle}-{p.rsplit('/', 1)[1]}" for p in server_paths}
        api_append_many(pair.api, server)
        on_b = {p: f"b-{cycle}-{p.rsplit('/', 1)[1]}" for p in b_paths}
        assert await append_lines(b.cdp, on_b) == []
        await asyncio.sleep(SUSPENDED_S)

        await a.cdp.resume()
        on_a = {p: f"a-off-{cycle}-{p.rsplit('/', 1)[1]}" for p in a_paths}
        assert await append_lines(a.cdp, on_a) == []
        await asyncio.sleep(WOKEN_OFFLINE_S)
        a.net.restore()
        for edits in (server, on_b, on_a):
            for p, m in edits.items():
                model[p].append(m)
        await asyncio.sleep(ONLINE_GAP_S)
        per_cycle.append(str(read_room_starts() - before))
        logger.warning("GAUNTLET mobile cycle %d rooms: %s", cycle, per_cycle[-1])

    t0 = time.monotonic()
    await await_converged(pair.api, pair.vaults, root, Expect({p: list(m) for p, m in model.items()}), deadline_s=300)
    logger.warning("GAUNTLET mobile converged %.0fs after the last resume", time.monotonic() - t0)
    over = budget.check(devices=2)
    assert over is None, f"{over}; per cycle: {per_cycle}"
