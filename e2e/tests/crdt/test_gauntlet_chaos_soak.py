"""Gauntlet 5: a short seeded chaos soak, two devices plus an MCP writer.

Each op is one random choice: a device appends, renames or deletes; the MCP
writer edits, renames, deletes or restores; a device's link is cut (half-open
or refused) for a few seconds; and each device is hard-killed and relaunched
once. Ops are issued one at a time with short gaps, so they overlap only in
propagation, which is where real races live.

The seed is logged (`GAUNTLET soak seed=`); rerun one with E2E_SOAK_SEED. The
op log is printed on failure.

Oracle at quiesce. Ops on the same note that race in flight have more than one
correct outcome, so the expectation is built only from what is unambiguous:
  * every device's disk equals the server, byte for byte, no conflict copy;
  * no marker appears twice anywhere (no duplicated text);
  * a note never deleted holds every marker an op confirmed, exactly once, at
    the path the model tracked, and its earlier paths are gone;
  * every path on the server belongs to some note the soak created.
Notes deleted at any point (restored or not) are checked for the first and
last only: no duplicates, no stray paths.
"""

from __future__ import annotations

import asyncio
import logging
import os
import random
import time
import uuid
from dataclasses import dataclass, field

import pytest

from helpers.convergence import Expect, await_converged, server_state
from helpers.gauntlet import append_lines, create_notes, delete, rename

logger = logging.getLogger(__name__)

NOTES = 30
SOAK_S = float(os.environ.get("E2E_SOAK_SECONDS", "330"))
# A note just renamed or deleted takes no rename/delete/restore for this long,
# so two structural ops never race on one note (their outcome is ambiguous).
SETTLE_S = 20


@dataclass
class Note:
    path: str
    anchor: str
    markers: list[str] = field(default_factory=list)
    alive: bool = True
    ever_deleted: bool = False
    old_paths: set[str] = field(default_factory=set)
    all_paths: set[str] = field(default_factory=set)
    restore_op: str | None = None
    busy_until: float = 0.0


@pytest.mark.timeout(1500)
async def test_chaos_soak_converges(gauntlet):
    seed = int(os.environ.get("E2E_SOAK_SEED") or random.randrange(1 << 30))
    logger.warning("GAUNTLET soak seed=%d", seed)
    rng = random.Random(seed)
    pair = await gauntlet("gsoak")
    api = pair.api
    devices = {d.name: d for d in pair.devices}
    root = f"Soak-{uuid.uuid4().hex[:6]}"

    notes = [Note(f"{root}/n{i:02d}.md", f"anchor-{root}-{i:02d}") for i in range(NOTES)]
    for n in notes:
        n.all_paths.add(n.path)
    await create_notes(pair.a.cdp, {n.path: f"# {n.path}\n\n{n.anchor}\n" for n in notes})
    await await_converged(api, pair.vaults, root, Expect({n.path: [n.anchor] for n in notes}))

    log: list[str] = []
    seq = 0
    cut_until: dict[str, float] = {}
    to_restart = set(devices)
    t0 = time.monotonic()

    def note(msg: str) -> None:
        log.append(f"t={time.monotonic() - t0:6.1f} {msg}")

    def pick(pred) -> Note | None:
        pool = [n for n in notes if pred(n)]
        return rng.choice(pool) if pool else None

    def free(n: Note) -> bool:
        return n.alive and n.busy_until < time.monotonic()

    try:
        while (now := time.monotonic()) - t0 < SOAK_S:
            for name, until in list(cut_until.items()):
                if now >= until:
                    devices[name].net.restore()
                    del cut_until[name]
                    note(f"{name} link restored")
            seq += 1
            marker = f"m{seq:04d}-{root}"
            roll = rng.random()
            dev = devices[rng.choice(sorted(devices))]

            if roll < 0.40:
                n = pick(lambda n: n.alive)
                if n and await append_lines(dev.cdp, {n.path: marker}) == []:
                    n.markers.append(marker)
                    note(f"{dev.name} append {n.path} {marker}")
            elif roll < 0.60:
                n = pick(lambda n: n.alive)
                if n:
                    out = api.mcp_try("edit_note", {
                        "path": n.path, "mode": "replace_text",
                        "find": n.anchor, "replace": f"{n.anchor}\n{marker}",
                    })
                    # A path a device renamed to may not have reached the server yet.
                    if "error" not in out:
                        n.markers.append(marker)
                    note(f"mcp edit {n.path} {marker} -> {out}")
            elif roll < 0.67:
                n = pick(free)
                new = f"{root}/r{seq:04d}.md"
                if n and await rename(dev.cdp, n.path, new):
                    note(f"{dev.name} rename {n.path} -> {new}")
                    n.old_paths.add(n.path)
                    n.path = new
                    n.all_paths.add(new)
                    n.busy_until = time.monotonic() + SETTLE_S
            elif roll < 0.73:
                n = pick(free)
                new = f"{root}/w{seq:04d}.md"
                out = api.mcp_try("rename_note", {"old_path": n.path, "new_path": new}) if n else None
                if out is not None:
                    note(f"mcp rename {n.path} -> {new}: {out}")
                if out is not None and "error" not in out:
                    n.old_paths.add(n.path)
                    n.path = new
                    n.all_paths.add(new)
                    n.busy_until = time.monotonic() + SETTLE_S
            elif roll < 0.77:
                n = pick(free)
                if n and await delete(dev.cdp, [n.path]) == []:
                    note(f"{dev.name} delete {n.path}")
                    n.alive, n.ever_deleted = False, True
                    n.busy_until = time.monotonic() + SETTLE_S
            elif roll < 0.83:
                n = pick(free)
                out = api.mcp_try("delete_note", {"path": n.path}) if n else None
                if out is not None:
                    note(f"mcp delete {n.path} -> {out}")
                if out is not None and out.get("deleted"):
                    n.alive, n.ever_deleted = False, True
                    n.restore_op = out.get("delete_op_id")
                    n.busy_until = time.monotonic() + SETTLE_S
            elif roll < 0.89:
                n = pick(lambda n: not n.alive and n.restore_op and n.busy_until < time.monotonic())
                if n:
                    out = api.mcp_try("restore_deleted", {"op_id": n.restore_op})
                    note(f"mcp restore {n.path} -> {out}")
                    n.alive, n.restore_op = out.get("notes") == 1, None
                    n.busy_until = time.monotonic() + SETTLE_S
            elif roll < 0.96:
                if dev.name not in cut_until:
                    secs = rng.uniform(5, 20)
                    mode = rng.choice(("blackhole", "refuse"))
                    getattr(dev.net, mode)()
                    cut_until[dev.name] = time.monotonic() + secs
                    note(f"{dev.name} link {mode} for {secs:.0f}s")
            elif dev.name in to_restart and dev.name not in cut_until:
                note(f"{dev.name} hard kill + relaunch")
                to_restart.discard(dev.name)
                dev.inst.kill()
                await dev.inst.relaunch()
                note(f"{dev.name} relaunched")
            await asyncio.sleep(rng.uniform(0.3, 1.5))

        for name in to_restart:  # the dice may never have rolled a restart
            note(f"{name} hard kill + relaunch (end of soak)")
            devices[name].inst.kill()
            await devices[name].inst.relaunch()
        for name in list(cut_until):
            devices[name].net.restore()
            note(f"{name} link restored (quiesce)")

        stable = [n for n in notes if not n.ever_deleted]
        deleted_anchors = {n.anchor for n in notes if n.ever_deleted}
        markers = {m for n in notes for m in n.markers}
        expect = Expect(
            {n.path: [n.anchor, *n.markers] for n in stable},
            exact=False,
            absent={p for n in stable for p in n.old_paths},
            at_most_once=markers | {n.anchor for n in notes},
            identities={n.anchor for n in notes},
            # Keep-both from an edit racing a delete: the copy holds a note
            # that was deleted at some point. Legitimate, not a sync error.
            copy_ok=lambda body: any(a in body for a in deleted_anchors),
        )
        await await_converged(api, pair.vaults, root, expect, deadline_s=360)

        known = {p for n in notes for p in n.all_paths}
        server, _ = server_state(api, root)
        stray = sorted(p for p in set(server) - known if "conflict" not in p.lower())
        assert not stray, f"paths no op created: {stray}"
        logger.warning(
            "GAUNTLET soak seed=%d: %d ops, %d stable notes, %d deleted at some point",
            seed, seq, len(stable), NOTES - len(stable),
        )
    except AssertionError as e:
        print(f"GAUNTLET soak seed={seed} op log:\n  " + "\n  ".join(log))
        raise AssertionError(f"soak seed={seed} (rerun: E2E_SOAK_SEED={seed}): {e}") from e
    except BaseException:
        print(f"GAUNTLET soak seed={seed} op log:\n  " + "\n  ".join(log))
        raise
