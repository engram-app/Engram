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
import datetime
import json
import logging
import time
import uuid

import pytest

from helpers.cdp import ENGINE_PATH as ENGINE
from helpers.convergence import Expect, await_converged, server_state
from helpers.gauntlet import (
    append_lines,
    buffer_inbound,
    create_notes,
    flush_inbound,
    creates_seen,
    hook_creates,
    inbound_held,
    release_creates,
    rename,
    replace_text,
    unhook_creates,
)
from helpers.log_oracle import receiver_device_id
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


# -- bug 8: an open note re-created by the orphaned-claim repair, no genesis ----


async def _type(cdp, text: str) -> str:
    """Type at the end of the ACTIVE editor (through the CodeMirror binding)."""
    return await cdp.evaluate(
        f"""(() => {{
            const ed = app.workspace.activeEditor?.editor;
            if (!ed) return 'no-editor';
            const end = {{line: ed.lastLine(), ch: ed.getLine(ed.lastLine()).length}};
            ed.replaceRange({json.dumps(text)}, end);
            return app.workspace.activeEditor.file.path;
        }})()"""
    )


@pytest.mark.timeout(900)
async def test_fuzz_bug8_open_note_recreated_by_orphan_repair(gauntlet):
    """B creates a note and types into it while OPEN; every crdt_create is
    dropped, through an offline restart, so the server never gets the row.
    Back online, enroll's STEP1 meets note_not_found and the orphaned-claim
    repair re-enqueues the create (without a genesis frame: the note is live
    bound). Creates are let through only once that repair has logged. B types
    more. The server and A must hold all of B's text."""
    pair = await gauntlet("gb8")
    b = pair.b
    root = _root("8")
    path = f"{root}/open.md"
    first, second, third = (f"{w}-{root}" for w in ("typed-first", "typed-before-restart", "typed-after"))
    since = datetime.datetime.now(datetime.timezone.utc).isoformat()

    await b.cdp.wait_for_stream_connected()
    await hook_creates(b.cdp, [], rest="drop")
    await b.cdp.vault_write(path, f"# Open\n\n{first}\n")
    assert await b.cdp.open_note_in_live_preview(path) == path
    assert await _type(b.cdp, f"\n{second}") == path
    await asyncio.sleep(12)  # past the first create's 10 s timeout, workspace saved

    b.net.refuse()
    b.inst.kill()
    await b.inst.relaunch()
    # The channel object is not built while offline, so after the relaunch the
    # drop sits one layer down: every outbound frame naming crdt_create is
    # swallowed at WebSocket.send (its request then times out, as a lost push
    # does) until window.__e2eAllowCreates.
    await b.cdp.evaluate(
        """(() => {
            const send = WebSocket.prototype.send;
            window.__e2eDroppedCreates = 0;
            WebSocket.prototype.send = function (data) {
                if (!window.__e2eAllowCreates && typeof data === 'string' && data.includes('"crdt_create"')) {
                    window.__e2eDroppedCreates++;
                    return;
                }
                return send.call(this, data);
            };
            return true;
        })()"""
    )
    active = await b.cdp.evaluate("app.workspace.activeEditor?.file?.path ?? null")
    logger.warning("GAUNTLET fuzz bug8: active editor after relaunch %r", active)
    if active != path:
        assert await b.cdp.open_note_in_live_preview(path) == path
    b.net.restore()

    end = time.monotonic() + 120
    orphan = []
    while not orphan:
        assert time.monotonic() < end, (
            "scenario not reached: no 'Orphaned index claim' log in 120 s; "
            f"crdt_create frames dropped: {await b.cdp.evaluate('window.__e2eDroppedCreates')}"
        )
        await asyncio.sleep(3)
        orphan = pair.api.list_logs(limit=500, since=since, query="Orphaned index claim")
    logger.warning("GAUNTLET fuzz bug8: orphan repair ran: %s", orphan[0].get("message"))
    dropped = await b.cdp.evaluate("window.__e2eAllowCreates = true; window.__e2eDroppedCreates")
    logger.warning("GAUNTLET fuzz bug8: %s crdt_create frames dropped after relaunch", dropped)
    await asyncio.sleep(5)
    assert await _type(b.cdp, f"\n{third}") == path

    await await_converged(pair.api, pair.vaults, root, Expect({path: [first, second, third]}), deadline_s=240)


@pytest.mark.timeout(600)
async def test_fuzz_bug2_catchup_fills_doc_before_create_ack(gauntlet):
    """The narrower bug 2 path: A's create is STORED, an MCP edit lands, A
    takes that edit into its Y.Doc through catch-up, and only THEN does A
    process its create-ack (whose drift merge diffs disk onto the doc). The
    create-ack reply is held, not the request. The MCP edit must survive."""
    pair = await gauntlet("gb2c")
    a = pair.a
    root = _root("2c")
    path = f"{root}/note.md"
    body = f"anchor-{root}"
    mcp = f"mcp-{root}"
    await a.cdp.wait_for_stream_connected()
    await hook_creates(a.cdp, ["holdack"])
    try:
        await a.cdp.vault_write(path, f"# Note\n\n{body}\n")
        await _wait_server_note(pair.api, path)
        assert await a.cdp.evaluate("!!window.__e2eAckHeld"), "create reply not held"
        pair.api.mcp_tool("edit_note", {"path": path, "mode": "replace_text", "find": body, "replace": f"{body}\n{mcp}"})
        note_id = await a.cdp.wait_for_note_id_for_path(path)
        in_doc = False
        end = time.monotonic() + 60
        while not in_doc and time.monotonic() < end:
            await a.cdp.trigger_catch_up()
            text = await a.cdp.evaluate(
                f"(async () => {{ const c = {ENGINE}.crdt; "
                f"return c?.getText ? await c.getText({json.dumps(note_id)}) : 'NO getText on syncEngine.crdt'; }})()",
                await_promise=True,
            )
            in_doc = bool(text) and mcp in text
            if not in_doc:
                await asyncio.sleep(2)
        assert in_doc, (
            f"ordering not forced: the MCP edit never reached A's Y.Doc before the ack (doc text {text!r})"
        )
        logger.warning("GAUNTLET fuzz bug2c: MCP edit in A's doc before the ack; releasing the ack")
        await release_creates(a.cdp)
        await asyncio.sleep(5)
    finally:
        calls = await unhook_creates(a.cdp)
    logger.warning("GAUNTLET fuzz bug2c: crdt_create calls on A %s", calls)
    await await_converged(pair.api, pair.vaults, root, Expect({path: [body, mcp]}))


# -- narrower orderings the fuzz author traced (seeds 1, 6, 11) -----------------
#
# Each first asserts its ordering was REACHED. "scenario not reached" is its
# own outcome: it says how hard the ordering is to hit in the real app, not
# that the bug is absent.


def _first_ts(entries: list[dict], needle: str) -> str | None:
    hits = sorted(e.get("timestamp", "") for e in entries if needle in e.get("message", ""))
    return hits[0] if hits else None


@pytest.mark.timeout(600)
async def test_fuzz_seed1_create_then_move_inside_first_push(gauntlet):
    """B creates a note and moves it while its first crdt_create is still in
    flight (templates / QuickAdd moving a new note into a folder). Reached:
    two crdt_create calls for ONE doc_id at two paths. Then A, holding the
    note idle and history-less, is force-quit and relaunched. Not doubled."""
    pair = await gauntlet("gs1")
    a, b = pair.a, pair.b
    root = _root("s1")
    old, new = f"{root}/Untitled.md", f"{root}/Inbox/Moved.md"
    seed = f"seed-{root}"
    await b.cdp.wait_for_stream_connected()
    await hook_creates(b.cdp, ["hold"], rest="hold")
    try:
        await b.cdp.vault_write(old, f"# New\n\n{seed}\n")
        end = time.monotonic() + 30
        while not await creates_seen(b.cdp):
            assert time.monotonic() < end, "scenario not reached: B never sent a crdt_create"
            await asyncio.sleep(0.2)
        assert await rename(b.cdp, old, new)
        await asyncio.sleep(2)
        await release_creates(b.cdp)
        await asyncio.sleep(5)
    finally:
        calls = await unhook_creates(b.cdp)
    on_disk = sorted(p.relative_to(b.vault).as_posix() for p in (b.vault / root).rglob("*.md"))
    logger.warning("GAUNTLET seed1: creates %s, B files %s", calls, on_disk)
    ids = {c["docId"] for c in calls}
    assert len(calls) >= 2 and len(ids) == 1 and len({c["path"] for c in calls}) >= 2, (
        f"scenario not reached: want 2+ crdt_create for one doc_id at two paths, got {calls}"
    )

    await asyncio.sleep(5)
    a.inst.kill()
    await a.inst.relaunch()
    await await_converged(pair.api, pair.vaults, root, Expect({}, exact=False, at_most_once={seed}))
    server, _ = server_state(pair.api, root)
    assert len(server) == 1, f"want one note, server has {sorted(server)}"
    (body,) = server.values()
    assert body.count(seed) == 1, f"server body doubled: {body!r} (B files {on_disk})"


@pytest.mark.timeout(600)
async def test_fuzz_seed6_create_reply_then_update_back_to_back(gauntlet):
    """A creates a note. Everything the server sends A is held from the moment
    the crdt_create goes out; an MCP edit commits and its broadcast queues
    behind the reply; then both are delivered back to back, reply first.
    Reached: A logs "gap-heal fired" or "load interlock" BEFORE "CRDT create
    ok". No "(conflict" copy, MCP edit everywhere."""
    pair = await gauntlet("gs6")
    a = pair.a
    root = _root("s6")
    path = f"{root}/note.md"
    body, mcp = f"anchor-{root}", f"mcp-{root}"
    since = datetime.datetime.now(datetime.timezone.utc).isoformat()
    await a.cdp.wait_for_stream_connected()
    await hook_creates(a.cdp, ["pass"])
    await buffer_inbound(a.cdp, on_create=True)
    try:
        await a.cdp.vault_write(path, f"# Note\n\n{body}\n")
        await _wait_server_note(pair.api, path)
        pair.api.mcp_tool("edit_note", {"path": path, "mode": "replace_text", "find": body, "replace": f"{body}\n{mcp}"})
        await asyncio.sleep(2)
        held = await inbound_held(a.cdp)
    finally:
        flushed = await flush_inbound(a.cdp)
        await unhook_creates(a.cdp)
    logger.warning("GAUNTLET seed6: delivered %d held frames back to back (%d when checked)", flushed, held)

    device = receiver_device_id(a.vault)
    end = time.monotonic() + 90
    while True:
        logs = pair.api.list_logs(limit=1000, since=since, device_id=device or "")
        ok = _first_ts(logs, "CRDT create ok")
        early = [t for t in (_first_ts(logs, "gap-heal fired"), _first_ts(logs, "load interlock")) if t]
        if ok or time.monotonic() > end:
            break
        await asyncio.sleep(3)
    assert ok, f"no 'CRDT create ok' from A in 90 s (held {held} frames)"
    assert early and min(early) < ok, (
        f"scenario not reached: no gap-heal/load-interlock before 'CRDT create ok' ({ok}); "
        f"early={early}, held frames={held}"
    )
    await await_converged(pair.api, pair.vaults, root, Expect({path: [body, mcp]}))


@pytest.mark.timeout(600)
async def test_fuzz_seed11_discovered_note_edit_then_offline_in_debounce(gauntlet):
    """A edits a DISCOVERED note (arrived by catch-up, never opened) while it
    is closed and drops offline inside the debounce; B edits a different
    line; A reconnects. Each line exactly once (no doubled body). A conflict
    copy is recorded and asserted separately, last, so the two outcomes stay
    distinguishable. Reached: the server's AUTHORITATIVE text lacks A's edit
    after A went offline (it was not pushed in time)."""
    pair = await gauntlet("gs11")
    a, b = pair.a, pair.b
    root = _root("s11")
    path = f"{root}/note.md"
    lines = [f"line{i}-{root}" for i in range(1, 6)]
    a.net.refuse()
    pair.api.create_note(path, "# Note\n\n" + "\n".join(lines) + "\n")
    wait_for_file(b.vault, path)
    a.net.restore()
    wait_for_file(a.vault, path)

    edit_a, edit_b = f"A-edited-{root}", f"B-edited-{root}"
    assert await replace_text(a.cdp, path, lines[1], edit_a)
    await asyncio.sleep(0.1)  # inside the debounce: the push has not fired
    a.net.refuse()
    await asyncio.sleep(2)
    server_now, _ = server_state(pair.api, root)
    assert edit_a not in server_now.get(path, ""), (
        "scenario not reached: A's edit reached the server before A went offline"
    )
    assert await replace_text(b.cdp, path, lines[3], edit_b)
    await asyncio.sleep(10)
    a.net.restore()

    keep = [lines[0], lines[2], lines[4]]
    await await_converged(
        pair.api, pair.vaults, root,
        Expect(
            {path: [*keep, edit_a, edit_b]},
            exact=False,
            at_most_once={lines[1], lines[3]},
            copy_ok=lambda body: True,  # recorded and asserted separately below
        ),
    )
    server, _ = server_state(pair.api, root)
    stray = sorted(set(server) - {path})
    logger.warning("GAUNTLET seed11: final files %s", sorted(server))
    assert all("conflict" in p.lower() for p in stray), f"unexpected notes: {stray}"
    assert not stray, f"merged correctly, but a conflict copy appeared: {stray}"


@pytest.mark.timeout(600)
async def test_remote_rename_while_device_offline(gauntlet):
    """B is offline while A renames a note and keeps editing it. B
    reconnects. B ends with the note at the NEW path, holding A's edits,
    and nothing at the old path (a remote rename must not be ignored)."""
    pair = await gauntlet("grr")
    a, b = pair.a, pair.b
    root = _root("rr")
    old, new = f"{root}/before.md", f"{root}/after.md"
    seed = f"seed-{root}"
    await create_notes(a.cdp, {old: f"# Note\n\n{seed}\n"})
    await await_converged(pair.api, pair.vaults, root, Expect({old: [seed]}))

    b.net.refuse()
    assert await rename(a.cdp, old, new)
    edits = [f"after-rename-{i}-{root}" for i in range(3)]
    for e in edits:
        await asyncio.sleep(1)
        assert await append_lines(a.cdp, {new: e}) == []
    await asyncio.sleep(3)
    b.net.restore()
    await await_converged(pair.api, pair.vaults, root, Expect({new: [seed, *edits]}, absent={old}))


@pytest.mark.timeout(600)
async def test_undo_on_closed_note_sticks(gauntlet):
    """A appends a line to a CLOSED note, waits for it to sync, then removes
    that same line (the file returns to its earlier text, as an undo or a
    revert from another app does). The removal must reach the server and B,
    and the line must not come back on A."""
    pair = await gauntlet("gundo")
    a = pair.a
    root = _root("undo")
    path = f"{root}/note.md"
    seed = f"seed-{root}"
    before = f"# Note\n\n{seed}\n"
    await create_notes(a.cdp, {path: before})
    await await_converged(pair.api, pair.vaults, root, Expect({path: [seed]}))

    added = f"undo-me-{root}"
    assert await append_lines(a.cdp, {path: added}) == []
    await await_converged(pair.api, pair.vaults, root, Expect({path: [seed, added]}))

    await create_notes(a.cdp, {path: before})  # vault.modify back to the earlier text
    await await_converged(pair.api, pair.vaults, root, Expect({path: [seed]}, at_most_once={added}))
    await asyncio.sleep(10)
    body = (a.vault / path).read_text(encoding="utf-8")
    assert added not in body, f"the undone line came back on A: {body!r}"
    server, _ = server_state(pair.api, root)
    assert added not in server.get(path, ""), f"the undone line is back on the server: {server.get(path)!r}"
