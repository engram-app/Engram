"""Gauntlet 8: real-Obsidian checks of the plugin sim fuzz's probable bugs.

The sim stands in for the CodeMirror binding and the socket, so some of what
it flags cannot happen in the real app (it over-reported 2 of 7). Each test
here reproduces one flagged scenario in real Obsidian and asserts the outcome
the fuzz said breaks. Names carry the fuzz bug number.

All use whole-folder convergence (helpers/convergence.py): every disk equals
the server byte for byte, each marker exactly once, no conflict copy.
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid

import pytest

from helpers.convergence import Expect, await_converged
from helpers.gauntlet import (
    append_lines,
    create_notes,
    creates_seen,
    hook_creates,
    release_creates,
    rename,
    replace_text,
    unhook_creates,
)
from helpers.vault import wait_for_file

logger = logging.getLogger(__name__)


def _root(tag: str) -> str:
    return f"Fuzz{tag}-{uuid.uuid4().hex[:6]}"


async def _wait_server_note(api, path: str, timeout: float = 60) -> None:
    end = time.monotonic() + timeout
    while api.get_note(path) is None:
        assert time.monotonic() < end, f"{path} never reached the server"
        await asyncio.sleep(0.5)


# -- bug 1: rename doubling --------------------------------------------------


@pytest.mark.timeout(600)
@pytest.mark.parametrize("what", ["note", "folder"])
async def test_fuzz_bug1_rename_on_b_then_idle_a_restarts(gauntlet, what):
    """B renames a note (or its folder) A holds idle; A restarts on its kept
    profile. The server body must not double and must equal B's."""
    pair = await gauntlet("gb1")
    a, b = pair.a, pair.b
    root = _root("1")
    old = f"{root}/F/note.md"
    seed = f"seed-{root}"
    await create_notes(b.cdp, {old: f"# Note\n\n{seed}\nline two\n"})
    await await_converged(pair.api, pair.vaults, root, Expect({old: [seed]}))

    new = f"{root}/F/note-renamed.md" if what == "note" else f"{root}/G/note.md"
    assert await rename(b.cdp, old if what == "note" else f"{root}/F", new if what == "note" else f"{root}/G")
    a.inst.kill()
    await a.inst.relaunch()
    await await_converged(pair.api, pair.vaults, root, Expect({new: [seed, "line two"]}, absent={old}))


@pytest.mark.timeout(600)
async def test_fuzz_bug1_rename_on_b_while_a_edits_closed(gauntlet):
    """Variant: after B's rename, A (offline, not yet told) edits the note
    while it is closed, then restarts. One note, at the new path, with the
    edit on the server, and no conflict copy."""
    pair = await gauntlet("gb1e")
    a, b = pair.a, pair.b
    root = _root("1e")
    old, new = f"{root}/note.md", f"{root}/note-renamed.md"
    seed = f"seed-{root}"
    await create_notes(b.cdp, {old: f"# Note\n\n{seed}\n"})
    await await_converged(pair.api, pair.vaults, root, Expect({old: [seed]}))

    a.net.refuse()
    assert await rename(b.cdp, old, new)
    edit = f"a-edit-{root}"
    assert await append_lines(a.cdp, {old: edit}) == []
    await asyncio.sleep(2)
    a.inst.kill()
    a.net.restore()
    await a.inst.relaunch()
    await await_converged(pair.api, pair.vaults, root, Expect({new: [seed, edit]}, absent={old}))


# -- bug 2: lost edit during a re-sent create ---------------------------------


@pytest.mark.timeout(600)
async def test_fuzz_bug2_mcp_edit_survives_resent_create(gauntlet):
    """A's create is delayed so the open editor's syncStep1 lands first and
    meets note_not_found (the orphaned-claim path re-enqueues the create).
    An MCP edit lands after the first create is stored and before the re-sent
    create goes out. The MCP edit must survive."""
    pair = await gauntlet("gb2")
    a = pair.a
    root = _root("2")
    path = f"{root}/note.md"
    body = f"anchor-{root}"
    await a.cdp.wait_for_stream_connected()
    await hook_creates(a.cdp, ["delay:4000"], rest="hold")
    try:
        await a.cdp.vault_write(path, f"# Note\n\n{body}\n")
        assert await a.cdp.open_note_in_live_preview(path) == path
        await _wait_server_note(pair.api, path)
        mcp = f"mcp-{root}"
        pair.api.mcp_tool("edit_note", {"path": path, "mode": "replace_text", "find": body, "replace": f"{body}\n{mcp}"})
        await asyncio.sleep(2)
        await release_creates(a.cdp)
        await asyncio.sleep(5)
    finally:
        calls = await unhook_creates(a.cdp)
    logger.warning("GAUNTLET fuzz bug2: crdt_create calls on A %s", calls)
    await await_converged(pair.api, pair.vaults, root, Expect({path: [body, mcp]}))
    # Last, so a green run still says whether the orphaned-claim re-send happened.
    assert len(calls) >= 2, f"orphaned-claim re-send not reached (one crdt_create only): {calls}"


@pytest.mark.timeout(600)
async def test_fuzz_bug2_force_quit_before_create_ack(gauntlet):
    """Variant: A's create reaches the server but its ack never comes back;
    A is force-quit, an MCP edit lands, A restarts and opens the note."""
    pair = await gauntlet("gb2k")
    a = pair.a
    root = _root("2k")
    path = f"{root}/note.md"
    body = f"anchor-{root}"
    await a.cdp.wait_for_stream_connected()
    await hook_creates(a.cdp, ["noreply"])
    await a.cdp.vault_write(path, f"# Note\n\n{body}\n")
    await _wait_server_note(pair.api, path)
    calls = await creates_seen(a.cdp)
    a.inst.kill()
    mcp = f"mcp-{root}"
    pair.api.mcp_tool("edit_note", {"path": path, "mode": "replace_text", "find": body, "replace": f"{body}\n{mcp}"})
    await a.inst.relaunch()
    assert await a.cdp.open_note_in_live_preview(path) == path
    logger.warning("GAUNTLET fuzz bug2 variant: crdt_create calls before kill %s", calls)
    await await_converged(pair.api, pair.vaults, root, Expect({path: [body, mcp]}))


# -- bug 3: spurious own-create conflict copy ----------------------------------


@pytest.mark.timeout(600)
async def test_fuzz_bug3_late_create_ack_no_conflict_copy(gauntlet):
    """A creates a note; its create-ack is processed late; an MCP edit lands
    in between. No "(conflict" file, and the edit is everywhere."""
    pair = await gauntlet("gb3")
    a = pair.a
    root = _root("3")
    path = f"{root}/note.md"
    body = f"anchor-{root}"
    await a.cdp.wait_for_stream_connected()
    await hook_creates(a.cdp, ["lateack:6000"])
    try:
        await a.cdp.vault_write(path, f"# Note\n\n{body}\n")
        await _wait_server_note(pair.api, path)
        mcp = f"mcp-{root}"
        pair.api.mcp_tool("edit_note", {"path": path, "mode": "replace_text", "find": body, "replace": f"{body}\n{mcp}"})
        await asyncio.sleep(8)
    finally:
        await unhook_creates(a.cdp)
    await await_converged(pair.api, pair.vaults, root, Expect({path: [body, mcp]}))


# -- bug 5: edit pushed on a half-dead socket ----------------------------------


@pytest.mark.timeout(600)
async def test_fuzz_bug5_edit_pushed_on_half_dead_socket(gauntlet):
    """A edits a closed note; the link goes half-dead (socket still OPEN,
    nothing gets through) before the debounced push fires. The link stays
    dead until the heartbeat notices (up to ~60 s), then comes back. The edit
    must reach the server and B."""
    pair = await gauntlet("gb5")
    a = pair.a
    root = _root("5")
    path = f"{root}/note.md"
    seed = f"seed-{root}"
    await create_notes(a.cdp, {path: f"# Note\n\n{seed}\n"})
    await await_converged(pair.api, pair.vaults, root, Expect({path: [seed]}))

    edit = f"half-dead-{root}"
    assert await append_lines(a.cdp, {path: edit}) == []
    await asyncio.sleep(0.1)
    a.net.blackhole()
    await asyncio.sleep(75)  # two 30 s heartbeat ticks: the second closes the dead socket
    a.net.restore()
    await await_converged(pair.api, pair.vaults, root, Expect({path: [seed, edit]}))


# -- bug 7: two resolvers on a note with no local history ----------------------


@pytest.mark.timeout(600)
async def test_fuzz_bug7_two_devices_edit_different_lines_of_fresh_note(gauntlet):
    """A discovers a note via catch-up (created on the server while A was
    offline, so A holds no history for it). A and B then edit DIFFERENT lines
    of it at once, both closed. Merged body, no conflict copy."""
    pair = await gauntlet("gb7")
    a, b = pair.a, pair.b
    root = _root("7")
    path = f"{root}/note.md"
    lines = [f"line{i}-{root}" for i in range(1, 6)]
    a.net.refuse()
    pair.api.create_note(path, "# Note\n\n" + "\n".join(lines) + "\n")
    wait_for_file(b.vault, path)
    a.net.restore()
    wait_for_file(a.vault, path)

    edit_a, edit_b = f"A-edited-{root}", f"B-edited-{root}"
    hits = await asyncio.gather(
        replace_text(a.cdp, path, lines[1], edit_a),
        replace_text(b.cdp, path, lines[3], edit_b),
    )
    assert hits == [True, True], hits
    keep = [lines[0], lines[2], lines[4]]
    await await_converged(
        pair.api, pair.vaults, root,
        Expect({path: [*keep, edit_a, edit_b]}, at_most_once={lines[1], lines[3]}),
    )
    body = (a.vault / path).read_text(encoding="utf-8")
    assert lines[1] not in body and lines[3] not in body, f"a replaced line survived: {body!r}"
