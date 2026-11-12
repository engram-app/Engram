"""CRLF frontmatter and a duplicated key order, in real Obsidian (Engram-obsidian#697).

The backend and web app open a frontmatter block on `---` plus LF OR CRLF
(engram-app/Engram#1645, #2564). The plugin opened only on LF, so for a note
saved with Windows line endings it treated the whole block as body text:

  - a local save CLEARED the doc's frontmatter map and put the fence in the
    body Y.Text, so the server and web app lost the note's properties;
  - when the server's `normalize_doc` lifted the fence back out, the plugin's
    projection no longer "meant the same" as the CRLF file, so it rewrote the
    user's file with LF fences.

Healing races: the server's `normalize_doc` and an upgraded plugin can lift the
same fence at once. `frontmatter_order` is a Y.Array, so both appends survive
the merge and the order holds a key twice; #697 dedupes every reader of it.

Every test runs in its own run-unique folder; nothing here counts vault-wide.
The SERVER doc is read with `crdt_doc_probe`, never through a room, so reading
it does not heal it.
"""

from __future__ import annotations

import asyncio
import re
import time
import uuid
from pathlib import Path

import pytest

from helpers.crdt_doc_probe import (
    append_order_key,
    bind_room,
    damage_server_doc,
    read_server_doc,
    release_room,
)
from helpers.frontmatter_first_sync import fm_keys
from helpers.latency import DELIVERY_TIMEOUT
from helpers.lineage_probe import read_lineages
from helpers.quiescence import await_quiescent
from helpers.vault import list_notes, wait_for_content, write_binary

KEYS = ["title", "status", "area"]
FENCE = "---\r\ntitle: Crlf note\r\nstatus: draft\r\narea: sync\r\n---\r\n"
BODY = "\r\n# Heading\r\n\r\nbody line one\r\nbody line two\r\n"
CRLF_NOTE = FENCE + BODY
# A body that starts with `-`, the character the fence also starts with: a
# heal that diffs to the body (instead of deleting exactly the fence) trims
# that shared `-` and, merged with another device's lift, eats the list marker.
LIST_BODY = "- item one\r\n- item two\r\n"


def _lf(text: str) -> str:
    """The plugin's and server's `toLf`: every CRLF pair and lone CR as LF.
    Markdown docs hold LF only, and every file sync writes is LF."""
    return re.sub(r"\r\n?", "\n", text)


# Long enough for a server lift, its fan-out and any disk rewrite it causes to
# land; well inside the crdt job's per-test budget.
SETTLE_S = 15
DUP_NOTE = "---\ntitle: Dup\nstatus: draft\narea: sync\n---\n\nbody\n"


def _folder() -> str:
    return f"E2E/Crlf-{uuid.uuid4().hex[:12]}"


def _disk(vault: Path, rel: str) -> str:
    # NOT helpers.vault.read_note: text mode turns CRLF into LF, which is the
    # very difference these tests check.
    return (vault / rel).read_bytes().decode("utf-8")


async def _arm(*cdps) -> None:
    for cdp in cdps:
        await cdp.arm_create_spy()


async def _assert_no_copies(folder: str, *cdps) -> None:
    for cdp in cdps:
        made = [p for p in await cdp.disarm_create_spy() if p.startswith(folder)]
        copies = [p for p in made if "(conflict" in p]
        assert copies == [], f"sync wrote conflict copies on port {cdp.port}: {copies}"


def _assert_one_note(folder: str, path: str, api_sync, *vaults: Path) -> None:
    for vault in vaults:
        assert list_notes(vault, folder) == [path], (
            f"{vault}: expected only {path} under {folder}, found {list_notes(vault, folder)}"
        )
    on_server = [n["path"] for n in api_sync.get_manifest()["notes"] if n["path"].startswith(folder)]
    assert on_server == [path], f"server holds {on_server} under {folder}, expected one note"


async def _wait_server_doc(vault_id: str, note_id: str, done, what: str):
    """Poll the server doc until `done(doc)`; fail with the last doc seen."""
    deadline = time.monotonic() + DELIVERY_TIMEOUT
    doc = read_server_doc(vault_id, note_id)
    while not done(doc) and time.monotonic() < deadline:
        await asyncio.sleep(1)
        doc = read_server_doc(vault_id, note_id)
    assert done(doc), f"server doc never reached: {what}\nlast doc: {doc}"
    return doc


def _properties_are_properties(doc, values: dict[str, str]) -> bool:
    """The frontmatter lives in the map (one entry per key, in order) and the
    body Y.Text holds no fence. `values` are the plain scalar values."""
    return (
        doc.unique_order == KEYS
        and all(doc.values.get(k, "").strip('"') == v for k, v in values.items())
        and not doc.body.startswith("---")
    )


async def _hold_bytes(
    vault: Path, rel: str, expected: str, why: str, *, exact: bool = True
) -> None:
    """Assert the file holds `expected` for the whole settle window.

    `exact` for a file sync wrote. Otherwise (the user's own CRLF file, or a
    note open in the editor, which Obsidian itself saves as LF: CodeMirror
    holds LF and TextFileView.save in app.js 1.12.7 writes it whenever it
    differs from the CRLF text it loaded) it may be the original CRLF bytes or
    their LF form, but never a MIX: the same text, one line ending."""
    deadline = time.monotonic() + SETTLE_S
    while time.monotonic() < deadline:
        now = _disk(vault, rel)
        detail = f"{why}\n--- expected ---\n{expected!r}\n--- on disk ---\n{now!r}"
        if exact:
            assert now == expected, detail
        else:
            assert _lf(now) == _lf(expected), detail
            uniform = "\r" not in now or now.count("\n") == now.count("\r\n")
            assert uniform, f"mixed line endings: {detail}"
        await asyncio.sleep(0.5)


def _assert_probe_sees_writers(vault_id: str, folder: str) -> None:
    """Self-check of `read_lineages`: the damaged fixture is written by the
    REST create and by the staging room, then healed by a device, so its doc
    holds several Yjs clients. A probe that reads zero here (it once read only
    a field `Repo.get` leaves nil, then only the snapshot without the update
    tail) cannot be trusted by test_97/98/100."""
    seen = read_lineages(vault_id, folder)
    assert seen.notes == 1 and seen.max_clients >= 2, f"lineage probe misreads: {seen}"


def _assert_keys_once(vault: Path, rel: str) -> str:
    text = _disk(vault, rel)
    assert fm_keys(text) == KEYS, f"{vault}: frontmatter keys {fm_keys(text)} != {KEYS}:\n{text!r}"
    return text


async def _damaged_note_on_both(
    folder, vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id, body=BODY
):
    """Fixture for the old-plugin-damaged shape, independent of the plugin under
    test: the server doc holds the fence in its body and an empty map, and both
    devices pull it as their FIRST sight of the note.

    Created over REST (the server's ingest lifts the frontmatter and converts
    to LF), then rewritten inside a pinned room to the legacy text, CRLF and
    fence in the body, so no rebind's `normalize_doc` heals it.
    Both gates stay shut until the damage is in place, so neither device sees
    the healthy version first."""
    path = f"{folder}/Damaged.md"
    note = FENCE + body
    last_line = body.strip().splitlines()[-1]
    await cdp_a.set_sync_blocked(True)
    await cdp_b.set_sync_blocked(True)
    try:
        api_sync.create_note(path, note)
        note_id = api_sync.wait_for_note_id(path)
        damage_server_doc(sync_vault_id, note_id, note)
        await _wait_server_doc(
            sync_vault_id,
            note_id,
            lambda d: d.order == [] and d.values == {} and d.body == note,
            "the damaged fixture shape (fence in body, empty map)",
        )
    finally:
        await cdp_a.set_sync_blocked(False)
        await cdp_b.set_sync_blocked(False)
    for cdp, vault in ((cdp_a, vault_a), (cdp_b, vault_b)):
        await cdp.trigger_full_sync()
        wait_for_content(vault, path, last_line, timeout=DELIVERY_TIMEOUT)
    # A device projects the damaged doc to the CRLF bytes verbatim.
    for vault in (vault_a, vault_b):
        assert _disk(vault, path) == note, f"{vault} did not pull the damaged note"
    return path, note_id


@pytest.mark.asyncio
async def test_crlf_note_syncs_with_properties_as_properties(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """[1] A CRLF note created on A's disk reaches B with its properties in the
    frontmatter map, body intact, A's bytes untouched, no copy, no duplicate."""
    folder = _folder()
    path = f"{folder}/Crlf.md"
    await _arm(cdp_a, cdp_b)

    write_binary(vault_a, path, CRLF_NOTE.encode())
    note_id = api_sync.wait_for_note_id(path)
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "body line two", timeout=DELIVERY_TIMEOUT)

    await _wait_server_doc(
        sync_vault_id,
        note_id,
        lambda d: _properties_are_properties(d, {"title": "Crlf note", "status": "draft"}),
        "the CRLF block lifted into the frontmatter map, no fence in the body",
    )
    assert read_server_doc(sync_vault_id, note_id).body == _lf(BODY)

    await _hold_bytes(vault_a, path, CRLF_NOTE, "sync damaged A's own file", exact=False)
    await _hold_bytes(vault_b, path, _lf(CRLF_NOTE), "B's file is not the LF projection")
    await _assert_no_copies(folder, cdp_a, cdp_b)
    _assert_one_note(folder, path, api_sync, vault_a, vault_b)


@pytest.mark.asyncio
async def test_crlf_property_edit_reaches_b(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """[2] Editing a property of a CRLF note on A: B gets the new value, the
    body is unchanged and no key is duplicated on either disk."""
    folder = _folder()
    path = f"{folder}/CrlfEdit.md"
    write_binary(vault_a, path, CRLF_NOTE.encode())
    note_id = api_sync.wait_for_note_id(path)
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "body line two", timeout=DELIVERY_TIMEOUT)
    await _arm(cdp_a, cdp_b)

    edited = CRLF_NOTE.replace("status: draft", "status: published")
    write_binary(vault_a, path, edited.encode())
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "status: published", timeout=DELIVERY_TIMEOUT)

    doc = await _wait_server_doc(
        sync_vault_id,
        note_id,
        lambda d: _properties_are_properties(d, {"status": "published"}),
        "the edited property in the frontmatter map, no fence in the body",
    )
    assert doc.body == _lf(BODY), f"server body changed by a property edit: {doc.body!r}"

    await _hold_bytes(vault_a, path, edited, "sync damaged A's own file", exact=False)
    await _hold_bytes(vault_b, path, _lf(edited), "B's file is not the LF projection")
    await _assert_no_copies(folder, cdp_a, cdp_b)
    _assert_one_note(folder, path, api_sync, vault_a, vault_b)


@pytest.mark.asyncio
async def test_damaged_crlf_note_heals_on_open(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """[3] A note the old plugin damaged (fence in the body, empty map) gets
    its fence lifted when A opens it, while the server room stays bound (so
    `normalize_doc` cannot be the one lifting it), and B converges. The
    body's CRs stay until the next room open, whose heal removes them: only
    the room removes CRs already in a doc. No key is duplicated, no copy."""
    folder = _folder()
    await _arm(cdp_a, cdp_b)
    path, note_id = await _damaged_note_on_both(
        folder, vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
    )
    try:
        print(f"\nbefore open: {read_server_doc(sync_vault_id, note_id)}")
        await cdp_a.open_in_editor(path)
        doc = await _wait_server_doc(
            sync_vault_id,
            note_id,
            lambda d: _properties_are_properties(d, {"title": "Crlf note", "status": "draft"}),
            "the damaged fence lifted into the map by the plugin",
        )
        print(f"healed: order={doc.order}")
        # One healer: the plugin lifts the fence but leaves the body's CRs to
        # the server room. This room is pinned, so they are still there.
        assert doc.body == BODY, f"the plugin touched CRs the room owns: {doc.body!r}"

        await _hold_bytes(vault_a, path, CRLF_NOTE, "healing damaged A's file", exact=False)
        await _hold_bytes(vault_b, path, _lf(CRLF_NOTE), "B's file is not the LF projection")
        _assert_probe_sees_writers(sync_vault_id, folder)
        _assert_keys_once(vault_a, path)
        _assert_keys_once(vault_b, path)

        # The next room open runs the room's heal, which removes them.
        release_room(note_id)
        await asyncio.to_thread(bind_room, sync_vault_id, note_id)
        await _wait_server_doc(
            sync_vault_id, note_id, lambda d: d.body == _lf(BODY), "the room heal of the body's CRs"
        )
        await _hold_bytes(vault_b, path, _lf(CRLF_NOTE), "B's file after the room heal")
        await _assert_no_copies(folder, cdp_a, cdp_b)
        _assert_one_note(folder, path, api_sync, vault_a, vault_b)
    finally:
        release_room(note_id)


@pytest.mark.asyncio
async def test_concurrent_heal_of_damaged_crlf_note(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """[4] A and B open the same damaged note at once while a fresh room binds
    and runs `normalize_doc`: up to three concurrent lifts of the same keys.
    Neither disk may hold a key twice, both converge to one key order, and the
    user's bytes are kept."""
    folder = _folder()
    await _arm(cdp_a, cdp_b)
    path, note_id = await _damaged_note_on_both(
        folder, vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id, body=LIST_BODY
    )
    note = FENCE + LIST_BODY
    try:
        release_room(note_id)
        await asyncio.gather(
            cdp_a.open_in_editor(path),
            cdp_b.open_in_editor(path),
            asyncio.to_thread(bind_room, sync_vault_id, note_id),
        )
        doc = await _wait_server_doc(
            sync_vault_id,
            note_id,
            lambda d: _properties_are_properties(d, {"title": "Crlf note", "status": "draft"}),
            "the damaged fence lifted into the map",
        )
        await await_quiescent(cdp_a, api_sync)
        await await_quiescent(cdp_b, api_sync)
        doc = read_server_doc(sync_vault_id, note_id)
        print(f"\nafter concurrent heal: raw order={doc.order}")
        assert doc.unique_order == KEYS, f"server doc: {doc}"
        assert doc.body == _lf(LIST_BODY), f"the concurrent heal ate body characters: {doc.body!r}"

        await _hold_bytes(vault_a, path, note, "the heal damaged A's file", exact=False)
        await _hold_bytes(vault_b, path, note, "the heal damaged B's file", exact=False)
        _assert_probe_sees_writers(sync_vault_id, folder)
        _assert_keys_once(vault_a, path)
        _assert_keys_once(vault_b, path)
        await _assert_no_copies(folder, cdp_a, cdp_b)
        _assert_one_note(folder, path, api_sync, vault_a, vault_b)
    finally:
        release_room(note_id)


@pytest.mark.asyncio
async def test_duplicate_order_key_projects_once_and_mints_nothing(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """[5] A doc whose `frontmatter_order` already holds a key twice (the merged
    result of two concurrent lifts) projects that key ONCE on both disks, and
    opening + saving the unchanged note on A writes nothing to the doc."""
    folder = _folder()
    path = f"{folder}/DupOrder.md"
    api_sync.create_note(path, DUP_NOTE)
    note_id = api_sync.wait_for_note_id(path)
    for cdp, vault in ((cdp_a, vault_a), (cdp_b, vault_b)):
        await cdp.trigger_full_sync()
        wait_for_content(vault, path, "body", timeout=DELIVERY_TIMEOUT)

    append_order_key(sync_vault_id, note_id, "title")
    await _wait_server_doc(
        sync_vault_id,
        note_id,
        lambda d: d.order == [*KEYS, "title"],
        "the fixture's duplicated order key",
    )
    await await_quiescent(cdp_a, api_sync)
    await await_quiescent(cdp_b, api_sync)

    for vault in (vault_a, vault_b):
        deadline = time.monotonic() + SETTLE_S
        while time.monotonic() < deadline:
            _assert_keys_once(vault, path)
            await asyncio.sleep(0.5)

    before = read_server_doc(sync_vault_id, note_id).state_vector
    await cdp_a.open_in_editor(path)
    await cdp_a.vault_write(path, _disk(vault_a, path))
    await asyncio.sleep(SETTLE_S)
    await await_quiescent(cdp_a, api_sync)
    after = read_server_doc(sync_vault_id, note_id)
    assert after.state_vector == before, (
        "opening and saving the unchanged note minted CRDT ops "
        f"(state vector {before} -> {after.state_vector}); doc: {after}"
    )
    _assert_keys_once(vault_a, path)
    assert _disk(vault_b, path) == DUP_NOTE, f"B's file changed: {_disk(vault_b, path)!r}"


@pytest.mark.asyncio
async def test_close_after_remote_edit_keeps_the_doc_lf(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """[6] A has a CRLF note open; B edits it; the edit is painted into A's
    editor; A closes the note, and Obsidian's unload save writes A's LF buffer
    back over the file. That save must read as an echo: the doc keeps the
    remote line exactly once and holds no CR, and B's file is the LF
    projection."""
    folder = _folder()
    path = f"{folder}/CloseAfterRemote.md"
    await _arm(cdp_a, cdp_b)
    write_binary(vault_a, path, CRLF_NOTE.encode())
    note_id = api_sync.wait_for_note_id(path)
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "body line two", timeout=DELIVERY_TIMEOUT)
    await cdp_a.open_in_editor(path)

    edited = _lf(CRLF_NOTE).replace("body line two\n", "body line two\nremote line\n")
    write_binary(vault_b, path, edited.encode())
    deadline = time.monotonic() + DELIVERY_TIMEOUT
    while "remote line" not in (await cdp_a.editor_text() or ""):
        assert time.monotonic() < deadline, "B's edit never reached A's open editor"
        await asyncio.sleep(0.5)
    await cdp_a.close_all_editors()
    await asyncio.sleep(SETTLE_S)
    await await_quiescent(cdp_a, api_sync)

    want = _lf(BODY).replace("body line two\n", "body line two\nremote line\n")
    doc = await _wait_server_doc(
        sync_vault_id, note_id, lambda d: d.body == want, "the remote edit, once, in LF"
    )
    assert doc.unique_order == KEYS, f"server doc: {doc}"
    await _hold_bytes(vault_a, path, edited, "A's file after close", exact=False)
    await _hold_bytes(vault_b, path, edited, "B's file is not the LF projection")
    _assert_keys_once(vault_a, path)
    await _assert_no_copies(folder, cdp_a, cdp_b)
    _assert_one_note(folder, path, api_sync, vault_a, vault_b)
