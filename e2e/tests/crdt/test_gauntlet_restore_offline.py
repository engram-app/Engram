"""Gauntlet 4: delete and restore while one device is offline, then it comes back.

Complements test_106 (both devices online, one restore). Safer delete
(Engram#2233) brings a note back under the SAME note_id at a fresh seq, so a
device that missed the whole sequence live has to sort it out from the seq
replay alone: the tombstone seq fence (plugin #642,
docs/context/crdt-tombstone-seq-fence.md). Device A watches everything live;
device B is offline (NetCut refuse) from before the first delete until the end.

Two folders, the two shapes the fence has to tell apart:
  * restore, then RENAME: folder R is deleted and restored over MCP, then A
    renames a restored note and appends to another. B, offline, appended to
    a third note of R before it knew R was deleted.
  * delete, restore, DELETE again: folder D ends deleted. B must not resurrect
    it from the restore in the middle of its replay.

Invariants: both devices converge on the server's folder, byte for byte; R's
notes are back (the renamed one only at its new path) with every edit once,
B's offline edit included; D is gone everywhere; no conflict copies.
"""

from __future__ import annotations

import asyncio
import uuid

import pytest

from helpers.convergence import Expect, await_converged
from helpers.gauntlet import append_lines, create_notes, rename
from helpers.vault import wait_for_file, wait_for_file_gone


@pytest.mark.timeout(900)
async def test_restore_round_trip_with_device_offline(gauntlet):
    pair = await gauntlet("grst")
    a, b, api = pair.a, pair.b, pair.api
    root = f"RestoreOff-{uuid.uuid4().hex[:6]}"
    r, d = f"{root}/R", f"{root}/D"

    model = {f"{folder}/n{i}.md": [f"seed-{folder.rsplit('/', 1)[1]}{i}-{root}"] for folder in (r, d) for i in range(4)}
    await create_notes(a.cdp, {p: f"# {p}\n\n{m[0]}\n" for p, m in model.items()})
    await await_converged(api, pair.vaults, root, Expect({p: list(m) for p, m in model.items()}))

    b.net.refuse()
    b_edit = f"b-offline-{root}"
    assert await append_lines(b.cdp, {f"{r}/n2.md": b_edit}) == []
    model[f"{r}/n2.md"].append(b_edit)

    # R: delete, restore, then rename one note and edit another on A.
    op_r = api.mcp_tool("delete_folder", {"folder": r, "recursive": True})["delete_op_id"]
    # D: delete, restore, delete.
    op_d = api.mcp_tool("delete_folder", {"folder": d, "recursive": True})["delete_op_id"]
    for i in range(4):
        wait_for_file_gone(a.vault, f"{r}/n{i}.md")
        wait_for_file_gone(a.vault, f"{d}/n{i}.md")
    for op in (op_r, op_d):
        restored = api.mcp_tool("restore_deleted", {"op_id": op})
        assert restored["notes"] == 4 and restored["skipped"] == [], restored
    for i in range(4):
        wait_for_file(a.vault, f"{r}/n{i}.md")
        wait_for_file(a.vault, f"{d}/n{i}.md")

    assert await rename(a.cdp, f"{r}/n0.md", f"{r}/n0-after-restore.md")
    model[f"{r}/n0-after-restore.md"] = model.pop(f"{r}/n0.md")
    a_edit = f"a-after-restore-{root}"
    assert await append_lines(a.cdp, {f"{r}/n1.md": a_edit}) == []
    model[f"{r}/n1.md"].append(a_edit)

    api.mcp_tool("delete_folder", {"folder": d, "recursive": True})
    gone = {p for p in model if p.startswith(f"{d}/")}
    for p in gone:
        model.pop(p)
        wait_for_file_gone(a.vault, p)
    await asyncio.sleep(3)

    b.net.restore()
    await await_converged(
        api,
        pair.vaults,
        root,
        Expect({p: list(m) for p, m in model.items()}, absent=gone | {f"{r}/n0.md"}),
        deadline_s=300,
    )
