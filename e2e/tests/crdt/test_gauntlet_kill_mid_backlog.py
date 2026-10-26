"""Gauntlet 3: hard-killed in the middle of healing 1,000 diverged notes, then relaunched.

A phone that comes back online with a large backlog is exactly the device the
OS kills mid-drain (memory pressure, the user swiping it away). Whatever the
drain had in flight (a heal room, a pooled room-free read, a half-written
acked snapshot in IndexedDB) is cut off, and the relaunch must pick up from
whatever survived on disk and in the profile.

Device A holds 1,000 synced notes, goes offline, and meanwhile every note is
changed server-side (and 30 locally on A). The network returns, the drain
starts, and A is SIGKILLed as soon as the first notes land. It relaunches on
the same profile (ObsidianInstance.kill/relaunch keeps IndexedDB).

Invariants: the whole folder converges (server == disk byte for byte, every
server and offline marker exactly once, no conflict copy), and room starts
across drain + kill + relaunch stay inside the #644 heal-room budget.
"""

from __future__ import annotations

import asyncio
import logging
import random
import time
import uuid

import pytest

from helpers.convergence import Expect, await_converged, disk_state
from helpers.gauntlet import RoomBudget, api_append_many, append_lines, create_notes

logger = logging.getLogger(__name__)

NOTES = 1000
A_OFFLINE_EDITS = 30
# Kill as soon as the drain is visibly under way, well before it can finish.
KILL_AFTER_HEALED = 20


@pytest.mark.timeout(1800)
async def test_kill_mid_heal_backlog_then_relaunch_converges(gauntlet):
    pair = gauntlet("gkill", with_b=False)
    a = pair.a
    rng = random.Random(1000)
    root = f"Backlog-{uuid.uuid4().hex[:6]}"

    model = {f"{root}/d{i % 20:02d}/n-{i:04d}.md": [f"seed-{root}-{i:04d}"] for i in range(NOTES)}
    await create_notes(a.cdp, {p: f"# {p}\n\n{m[0]}\n" for p, m in model.items()})
    await await_converged(pair.api, pair.vaults, root, Expect({p: list(m) for p, m in model.items()}), deadline_s=900)

    a.net.refuse()
    server = {p: f"srv-{p.rsplit('/', 1)[1]}" for p in model}
    api_append_many(pair.api, server)
    local = {p: f"local-{p.rsplit('/', 1)[1]}" for p in rng.sample(sorted(model), A_OFFLINE_EDITS)}
    assert await append_lines(a.cdp, local) == []
    for edits in (server, local):
        for p, m in edits.items():
            model[p].append(m)
    await asyncio.sleep(3)

    budget = RoomBudget("backlog drain + kill + relaunch")
    a.net.restore()
    t0 = time.monotonic()
    healed = 0
    while time.monotonic() - t0 < 300:
        disk, _ = disk_state(a.vault, root)
        healed = sum(1 for p, body in disk.items() if p in server and server[p] in body)
        if healed >= KILL_AFTER_HEALED:
            break
        await asyncio.sleep(0.5)
    logger.warning(
        "GAUNTLET backlog: killing A with %d/%d notes healed, %.0fs into the drain",
        healed, NOTES, time.monotonic() - t0,
    )
    assert healed >= KILL_AFTER_HEALED, f"drain made no progress in 300s ({healed} healed)"
    assert healed < NOTES, "drain finished before the kill; nothing was mid-drain"
    a.inst.kill()
    await asyncio.sleep(2)
    await a.inst.relaunch()

    await await_converged(pair.api, pair.vaults, root, Expect({p: list(m) for p, m in model.items()}), deadline_s=900)
    over = budget.check(devices=1)
    assert over is None, over
