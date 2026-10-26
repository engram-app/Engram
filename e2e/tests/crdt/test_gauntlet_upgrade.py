"""Gauntlet 1: upgrading from the previous RELEASE keeps a lived-in vault converged.

Every other e2e boots the candidate on an empty profile. Real users upgrade a
device that already holds hundreds of notes, months of CRDT history in
IndexedDB, and sometimes an edit made offline that never reached the server.
That device's first launch on the new build is when Engram#2242 struck: every
hydrated idle doc read as "undelivered" and took its own heal room.

Device A runs the published previous release (helpers/plugin_release.py) and
builds real history: 300 notes, repeated edits from both devices, renames, a
folder rename, deletes, an attachment. It then edits offline and is killed
before the edit can leave. The candidate build is installed over it and A
relaunches on the SAME Electron profile (ObsidianInstance.kill/relaunch).

Invariants, whole folder (helpers/convergence.py): server == each device's
disk byte for byte, every marker exactly once, no conflict copy, nothing
resurrected, the offline edit delivered; and the relaunch stays inside the
#644 heal-room budget.
"""

from __future__ import annotations

import asyncio
import logging
import random
import uuid

import pytest

import conftest as harness
from helpers.convergence import Expect, await_converged
from helpers.gauntlet import RoomBudget, append_lines, create_binary, create_notes, delete, rename
from helpers.plugin_release import PREVIOUS_VERSION, fetch_release, plugin_version

logger = logging.getLogger(__name__)

NOTES = 300
FOLDERS = 10
PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)


@pytest.mark.timeout(1500)
async def test_upgrade_from_previous_release_on_kept_profile(gauntlet):
    previous = fetch_release()
    candidate = harness.PLUGIN_SRC
    logger.warning(
        "GAUNTLET upgrade %s -> candidate %s", PREVIOUS_VERSION, plugin_version(candidate)
    )
    pair = gauntlet("gup", plugin_a=previous)
    a, b = pair.a, pair.b
    rng = random.Random(1390)
    root = f"Upgrade-{uuid.uuid4().hex[:6]}"
    model: dict[str, list[str]] = {}
    absent: set[str] = set()

    # 1. History on the previous release.
    seed = {}
    for i in range(NOTES):
        path = f"{root}/f{i % FOLDERS}/note-{i:03d}.md"
        seed[path] = f"# Note {i}\n\nseed-{root}-{i:03d}\n"
        model[path] = [f"seed-{root}-{i:03d}"]
    await create_notes(a.cdp, seed)
    await await_converged(pair.api, pair.vaults, root, Expect(dict(model)), deadline_s=600)

    for rnd in range(3):
        for dev, count in ((a, 100), (b, 50)):
            edits = {}
            for path in rng.sample(sorted(model), count):
                marker = f"edit-{dev.name}-{rnd}-{len(model[path])}-{path.rsplit('/', 1)[1]}"
                edits[path] = marker
                model[path].append(marker)
            assert await append_lines(dev.cdp, edits) == []
        await asyncio.sleep(2)

    for path in rng.sample(sorted(p for p in model if "/f9/" not in p), 20):
        new = path.replace(".md", "-renamed.md")
        assert await rename(a.cdp, path, new)
        model[new] = model.pop(path)
        absent.add(path)
    assert await rename(a.cdp, f"{root}/f9", f"{root}/f9-moved")
    for path in [p for p in model if p.startswith(f"{root}/f9/")]:
        model[path.replace("/f9/", "/f9-moved/")] = model.pop(path)
        absent.add(path)
    for dev, count in ((a, 20), (b, 5)):
        await await_converged(pair.api, pair.vaults, root, Expect(dict(model), absent=set(absent)))
        doomed = rng.sample(sorted(model), count)
        assert await delete(dev.cdp, doomed) == []
        for path in doomed:
            model.pop(path)
            absent.add(path)
    att = f"{root}/att/diagram.png"
    await create_binary(a.cdp, att, PNG)
    expect = Expect(dict(model), absent=set(absent), attachments={att: PNG})
    await await_converged(pair.api, pair.vaults, root, expect)

    # 2. An edit made offline that never leaves: cut, edit, kill.
    a.net.refuse()
    offline = {}
    for path in rng.sample(sorted(model), 10):
        offline[path] = f"offline-{path.rsplit('/', 1)[1]}"
        model[path].append(offline[path])
    assert await append_lines(a.cdp, offline) == []
    await asyncio.sleep(3)  # past the 500 ms debounce, into IndexedDB / the op queue
    a.inst.kill()

    # B keeps working while A is down, so A wakes up to diverged idle notes.
    remote = {}
    for path in rng.sample(sorted(model), 30):
        remote[path] = f"while-down-{path.rsplit('/', 1)[1]}"
        model[path].append(remote[path])
    assert await append_lines(b.cdp, remote) == []

    # 3. Upgrade: candidate over the previous release, same profile, network back.
    budget = RoomBudget("upgrade relaunch")
    a.net.restore()
    await a.inst.relaunch(plugin_src=candidate)
    running = await a.cdp.evaluate("app.plugins.plugins['engram-vault-sync'].manifest.version")
    assert running == plugin_version(candidate), f"A runs {running}, not the candidate"

    expect = Expect(dict(model), absent=set(absent), attachments={att: PNG})
    await await_converged(pair.api, pair.vaults, root, expect, deadline_s=300)
    over = budget.check(devices=2)
    assert over is None, over
