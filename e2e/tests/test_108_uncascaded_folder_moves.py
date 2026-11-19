"""Test 108: folders moved WITHOUT a cascade (O(1) folder rename plan,
Engram#2523), end to end in real Obsidian, REST and MCP.

With the `folder_ops` switch on, the S5 write stop (`Engram.Folders.WriteStop`,
release B) renames ONE folder row (`notes_cascaded = false`) and leaves every
note under it at its OLD stored path. Every reader must then show the note at
its folder chain plus its name (the S5/S6 read switches, release D). A reader
that still trusts the stored path shows a moved note at its old path, and a
writer that does lands a duplicate or tombstones the wrong file.

Each test first proves the move it reads really was uncascaded
(`folder_ops.assert_uncascaded`): on a cascading server every assertion here
would pass for the wrong reason.

Scenarios (one test each):
  1. offline nested folder rename on A while B edits a note in it
  2. MCP shows moved notes at the new path; write_note there edits, no duplicate
  3. an attachment in a moved folder is listed, downloadable and renamable
  4. a delete under a moved folder removes the NEW path and spares a decoy at
     the old path
  5. vault-root notes before and after a folder move elsewhere
  6. a chain of renames plus a nested move, read by every surface and pulled
     by a fresh device

All oracles are scoped to a per-test uuid prefix
(docs/context/e2e-session-vault-scoping-trap.md). These tests LEAVE folders
moved without a cascade behind (the session vault's `E2E/*108-*` trees, and
`E2E/Chain108-*` plus `E2E/RootMv108-*` in the resumed pair's vault), so any
vault they ran in reads every path by name from then on; a test that needs a
vault with no such move must check `folder_ops.moved_folder_count` first. The switch is stack-global,
so the suite must run serially (`folder_ops.folder_ops_on` enforces it).
"""

from __future__ import annotations

import logging
import time
import uuid

import pytest

from helpers import folder_ops
from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import wait_for_binary_delivery
from helpers.route_probe import arm_routes, read_routes
from helpers.vault import (
    TINY_PNG,
    delete_note,
    files_under,
    wait_for_content,
    wait_for_file_gone,
    wait_for_folder_gone,
    write_note,
)

logger = logging.getLogger(__name__)

_backstop = pytest.fixture(scope="module", autouse=True)(folder_ops.switch_backstop)

# Long enough for a late tombstone, duplicate or conflict copy to land.
SETTLE_SECONDS = 5


def _uid() -> str:
    return uuid.uuid4().hex[:12]


# -- setup and moves ----------------------------------------------------------


def _seed(api, vaults, notes: dict[str, str], attachments=(), prefix: str = "") -> dict:
    """Create `notes` (path -> body) and `attachments` over REST, wait until the
    server holds exactly them under `prefix` and every device has them.
    Returns the server rows."""
    for path, body in notes.items():
        api.create_note(path, body)
    for path in attachments:
        assert api.upload_attachment(path, TINY_PNG, "image/png") in (200, 201)
    rows, _ = folder_ops.wait_server_paths(api, prefix, {*notes, *attachments})
    for vault in vaults:
        for path, body in notes.items():
            wait_for_content(vault, path, body.splitlines()[-1])
        for path in attachments:
            assert wait_for_binary_delivery(vault, path, api) == TINY_PNG
    return rows


def _move(api, prefix: str, rows: dict, old: str, new: str, via="rest", vault_id=None) -> dict:
    """Rename folder `old` to `new` (REST or MCP), wait until the server shows
    every row moved with its id kept, prove the move was uncascaded.
    Returns the rows after the move."""
    if via == "rest":
        assert api.rename_folder(old, new) == 200
    else:
        api.mcp_tool("rename_folder", {"old_folder": old, "new_folder": new, "vault_id": vault_id})
    expected = {p.replace(old, new, 1) if p.startswith(f"{old}/") else p for p in rows}
    after, manifest = folder_ops.wait_server_paths(api, prefix, expected)
    for path, row in rows.items():
        dest = path.replace(old, new, 1) if path.startswith(f"{old}/") else path
        assert after[dest]["id"] == row["id"], f"{path} changed identity moving to {dest}"
    folder_ops.assert_uncascaded(manifest, new)
    return after


# -- MCP and REST read oracles ------------------------------------------------


def _mcp_list(api, vault_id: str, folder: str, recursive: bool = False):
    """MCP list_folder, every page: (note paths, attachment paths, folder paths)."""
    notes: set[str] = set()
    atts: set[str] = set()
    folders: set[str] = set()
    cursor = None
    for _ in range(1000):
        args = {"folder": folder, "recursive": recursive, "vault_id": vault_id}
        if cursor:
            args["cursor"] = cursor
        page = api.mcp_tool("list_folder", args)["structuredContent"]
        notes |= {n["path"] for n in page["notes"]}
        atts |= {a["path"] for a in page["attachments"]}
        folders |= {f["folder"] for f in page["folders"]}
        cursor = page.get("next_cursor")
        if not cursor:
            return notes, atts, folders
    raise AssertionError(f"MCP list_folder({folder!r}) never reached its last page")


def _text(result: dict) -> str:
    return "\n".join(c.get("text", "") for c in result.get("content") or [])


def _get_notes(api, vault_id: str, paths: list[str]) -> tuple[dict, str, dict]:
    result = api.mcp_tool("get_notes", {"paths": paths, "vault_id": vault_id})
    return {n["path"]: n for n in result["structuredContent"]["notes"]}, _text(result), result


def _assert_get_notes(api, vault_id: str, live: list[str], gone: list[str] = ()) -> dict:
    """MCP get_notes finds every `live` path AT that path (payload and the
    `**Path:**` header) and none of `gone`. Asked three ways, so a failure
    names which: the live paths alone, the old paths alone, then both in one
    batch (a client holding a stale path asks exactly that). Returns
    {path: payload} of the live-only read."""
    calls = [("live only", list(live), []), ("gone only", [], list(gone))]
    if live and gone:
        calls.append(("live and gone in one batch", list(live), list(gone)))
    first = None
    for how, want, absent in calls:
        if not want and not absent:
            continue
        by_path, text, result = _get_notes(api, vault_id, [*want, *absent])
        first = first or by_path
        for path in want:
            assert by_path.get(path, {}).get("found") is True, (
                f"get_notes ({how}) missed {path}: {result}"
            )
            assert f"**Path:** {path}\n" in text, (
                f"get_notes ({how}) printed another path for {path}: {text}"
            )
            folder = path.rsplit("/", 1)[0] if "/" in path else ""
            assert by_path[path].get("folder") == folder, (
                f"get_notes ({how}) folder for {path}: {by_path[path]}"
            )
        for path in absent:
            assert by_path.get(path, {}).get("found") is not True, (
                f"get_notes ({how}) still finds the old path {path}: {by_path.get(path)}"
            )
    return first or {}


def _recent_paths(api, vault_id: str, **filters) -> set[str]:
    """MCP search_notes with NO query (recent mode, filters apply)."""
    result = api.mcp_tool("search_notes", {"limit": 20, "vault_id": vault_id, **filters})
    return {r.get("source_path") for r in result["structuredContent"]["results"]}


def _tree(api, prefix: str) -> tuple[set[str], set[str]]:
    """GET /vault/tree under `prefix`: (note+attachment paths, folder paths)."""
    tree = api.get_vault_tree()
    files = {
        r["path"]
        for r in (tree.get("notes") or []) + (tree.get("attachments") or [])
        if r["path"].startswith(prefix)
    }
    folders = {f["name"] for f in tree.get("folders") or [] if f["name"].startswith(prefix)}
    return files, folders


def _assert_disk_holds(vault, prefix: str, expected: set[str], who: str) -> None:
    """Exactly `expected` under `prefix` on a device, still so after a settle."""
    folder_ops.wait_disk_paths(vault, prefix, expected, who)
    time.sleep(SETTLE_SECONDS)
    got = files_under(vault, prefix)
    assert got == expected, (
        f"{who} drifted after settling: missing {sorted(expected - got)}, "
        f"extra {sorted(got - expected)}"
    )


# -- 1: offline nested folder rename on two devices --------------------------


@pytest.mark.asyncio
async def test_offline_nested_folder_rename_keeps_peer_edit(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """A (socket and REST down) renames a nested folder holding notes and an
    attachment; B, online, edits a note in it; A reconnects. Both converge:
    every file at the new path, old folder gone, no conflict copy, B's edit
    kept on the same note."""
    root = f"E2E/Nest108-{_uid()}"
    old, new = f"{root}/inner", f"{root}/renamed"
    notes = {
        f"{root}/keep.md": "# Keep\n\nsibling 108",
        f"{old}/n1.md": "# N1\n\nfirst 108",
        f"{old}/deep/n2.md": "# N2\n\nsecond 108",
    }
    marker = f"peer edit {_uid()}"
    async with folder_ops.folder_ops_on(cdp_a, cdp_b, write_stop=True):
        rows = _seed(api_sync, (vault_a, vault_b), notes, [f"{old}/img.png"], prefix=root)
        await folder_ops.wait_folders_known(cdp_a, old, root, teach=True)
        await folder_ops.wait_folders_known(cdp_b, old, root, teach=True)

        arm_routes(root)
        async with folder_ops.socket_down(cdp_a, rest_too=True):
            await cdp_a.rename_file(old, new)
            write_note(vault_b, f"{old}/n1.md", f"# N1\n\nfirst 108\n\n{marker}\n")
            api_sync.wait_for_note_content(f"{old}/n1.md", marker)
        await cdp_a.wait_for_crdt_queue_drain(timeout=45)

        expected = folder_ops.moved(rows, old, new)
        after, manifest = folder_ops.wait_server_paths(api_sync, root, expected)
        folder_ops.assert_uncascaded(manifest, new)
        folder_ops.same_ids(
            {p: r for p, r in rows.items() if p != f"{old}/n1.md"}, after, old, new
        )
        assert after[f"{new}/n1.md"]["id"] == rows[f"{old}/n1.md"]["id"], (
            "B's edit and A's move forked n1 into two notes"
        )
        api_sync.wait_for_note_content(f"{new}/n1.md", marker)
        for who, vault in (("A", vault_a), ("B", vault_b)):
            wait_for_content(vault, f"{new}/n1.md", marker)
            wait_for_folder_gone(vault, old)
            _assert_disk_holds(vault, root, expected, who)
        assert (vault_b / f"{new}/img.png").read_bytes() == TINY_PNG
        routes = read_routes()
        logger.info("test_108 offline nested rename: %s", routes)
        assert routes.folder_op == 1, f"want exactly A's one folder_op: {routes}"


# -- 2: MCP shows moved notes at their new path -------------------------------


@pytest.mark.asyncio
async def test_mcp_reads_moved_notes_at_new_path(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """After a REST move and then an MCP move, MCP get_notes, list_folder and
    search_notes (query, recent+folder and tag modes) show the NEW path, the
    old one finds nothing, and write_note at the new path edits the same note."""
    uid = _uid()
    root = f"E2E/Mcp108-{uid}"
    src, mid, dst = f"{root}/src", f"{root}/mid", f"{root}/dst"
    token, tag = f"zzmovedpath{uid}", f"mv108{uid}"
    notes = {
        f"{src}/n1.md": f"---\ntags: [{tag}]\n---\n# N1\n\n{token} body 108",
        f"{src}/sub/n2.md": "# N2\n\nsecond 108",
    }
    vid = sync_vault_id
    async with folder_ops.folder_ops_on(cdp_a, cdp_b, write_stop=True):
        rows = _seed(api_sync, (vault_a, vault_b), notes, prefix=root)
        rows = _move(api_sync, root, rows, src, mid, via="rest")
        _assert_mcp_shows(api_sync, vid, root, mid, gone=src, tag=tag)
        rows = _move(api_sync, root, rows, mid, dst, via="mcp", vault_id=vid)
        _assert_mcp_shows(api_sync, vid, root, dst, gone=mid, tag=tag)

        # Query mode: the hit for the token names the note at its shown path.
        deadline = time.monotonic() + 90
        hits: list[dict] = []
        while not hits:
            assert time.monotonic() < deadline, f"search_notes never found {token}"
            result = api_sync.mcp_tool(
                "search_notes", {"query": token, "limit": 20, "vault_id": vid}
            )
            hits = [r for r in result["structuredContent"]["results"] if token in r["text"]]
            if not hits:
                time.sleep(5)
        assert {h.get("source_path") for h in hits} == {f"{dst}/n1.md"}, hits
        assert f"{src}/" not in _text(result) and f"{mid}/" not in _text(result), _text(result)

        # write_note at the shown path edits the moved note, no second row.
        found = _assert_get_notes(api_sync, vid, [f"{dst}/n1.md"])
        edit = f"written at the new path {uid}"
        api_sync.mcp_tool(
            "write_note",
            {
                "path": f"{dst}/n1.md",
                "content": f"# N1\n\n{token} {edit}",
                "base_hash": found[f"{dst}/n1.md"]["content_hash"],
                "vault_id": vid,
            },
        )
        api_sync.wait_for_note_content(f"{dst}/n1.md", edit)
        # No second note at any poll across the settle window, same id.
        after = folder_ops.hold_server_paths(api_sync, root, set(rows), SETTLE_SECONDS * 2)
        assert after[f"{dst}/n1.md"]["id"] == rows[f"{dst}/n1.md"]["id"], (
            "write_note at the shown path minted a second note"
        )
        # Recent mode (no query, no filter): the note just written is listed
        # at its shown path, never at a stored one.
        recent = _recent_paths(api_sync, vid)
        assert f"{dst}/n1.md" in recent, sorted(recent)
        assert not {p for p in recent if p and p.startswith((f"{src}/", f"{mid}/"))}, recent
        for who, vault in (("A", vault_a), ("B", vault_b)):
            wait_for_content(vault, f"{dst}/n1.md", edit)
            _assert_disk_holds(vault, root, set(rows), who)


def _assert_mcp_shows(api, vid: str, root: str, folder: str, gone: str, tag: str) -> None:
    n1, n2 = f"{folder}/n1.md", f"{folder}/sub/n2.md"
    _assert_get_notes(api, vid, [n1, n2], gone=[f"{gone}/n1.md", f"{gone}/sub/n2.md"])
    notes, _, subfolders = _mcp_list(api, vid, folder)
    assert notes == {n1}, f"list_folder({folder}) notes: {notes}"
    assert f"{folder}/sub" in subfolders, f"list_folder({folder}) folders: {subfolders}"
    assert _mcp_list(api, vid, gone)[0] == set(), f"list_folder({gone}) still lists notes"
    assert _recent_paths(api, vid, folder=folder) == {n1, n2}
    # Tags resolve through `note_attrs`, which the index pass writes
    # (`Engram.Search.NoteFilter`): as fresh as the vector index, so poll. A
    # moved note found by tag at any other path still fails at once.
    deadline = time.monotonic() + 90
    while (got := _recent_paths(api, vid, tags=[tag])) != {n1}:
        assert not got or got == {n1}, f"tag filter shows the note at {got}, want {n1}"
        assert time.monotonic() < deadline, f"tag filter never found {n1} (index lag or a bug)"
        time.sleep(3)
    assert _recent_paths(api, vid, folder=gone) == set()


# -- 3: attachments in a moved folder ----------------------------------------


@pytest.mark.asyncio
async def test_attachment_in_moved_folder_lists_downloads_and_renames(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_vault_id
):
    """After the folder move the attachment is listed and served at its new
    path (manifest, tree, MCP, REST GET, both devices), and renaming it
    afterwards from the plugin and then over REST moves the same row."""
    root = f"E2E/Att108-{_uid()}"
    old, new = f"{root}/src", f"{root}/dst"
    att = f"{old}/img.png"
    async with folder_ops.folder_ops_on(cdp_a, cdp_b, write_stop=True):
        rows = _seed(
            api_sync, (vault_a, vault_b), {f"{old}/n.md": "# N\n\nnote 108"}, [att], prefix=root
        )
        rows = _move(api_sync, root, rows, old, new)
        moved_att = f"{new}/img.png"

        resp = api_sync.get_attachment(moved_att, raw=True)
        assert resp.status_code == 200 and resp.content == TINY_PNG, (
            f"GET {moved_att}: {resp.status_code}"
        )
        assert api_sync.get_attachment(att).status_code == 404, f"{att} is still served"
        assert moved_att in _tree(api_sync, root)[0]
        assert _mcp_list(api_sync, sync_vault_id, new)[1] == {moved_att}
        assert _mcp_list(api_sync, sync_vault_id, old)[1] == set()
        for vault in (vault_a, vault_b):
            assert wait_for_binary_delivery(vault, moved_att, api_sync) == TINY_PNG
            wait_for_file_gone(vault, att)

        # Plugin rename of the moved attachment: one move, no re-upload.
        renamed = f"{new}/img2.png"
        arm_routes(root)
        await cdp_a.rename_file(moved_att, renamed)
        after, _ = folder_ops.wait_server_paths(api_sync, root, set(rows) - {moved_att} | {renamed})
        assert after[renamed]["id"] == rows[moved_att]["id"], "the rename changed the row"
        routes = read_routes()
        assert routes.attachment_rename == 1 and routes.attachment_upload == 0, routes
        assert wait_for_binary_delivery(vault_b, renamed, api_sync) == TINY_PNG

        # REST rename of it afterwards.
        final = f"{new}/img3.png"
        assert api_sync.rename_attachment(renamed, final) == 200
        after, _ = folder_ops.wait_server_paths(api_sync, root, set(rows) - {moved_att} | {final})
        assert after[final]["id"] == rows[moved_att]["id"], "the REST rename changed the row"
        assert api_sync.get_attachment(final, raw=True).content == TINY_PNG
        expected = set(after)
        for who, vault in (("A", vault_a), ("B", vault_b)):
            assert wait_for_binary_delivery(vault, final, api_sync) == TINY_PNG
            _assert_disk_holds(vault, root, expected, who)


# -- 4: delete under a moved folder -------------------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("origin", ["api", "plugin"])
async def test_delete_under_moved_folder_spares_old_path_decoy(
    origin, vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Delete a moved note: every device removes the file at its NEW path, and
    a decoy note created afterwards at the OLD path survives everywhere (a
    tombstone carrying the stored path would trash it)."""
    root = f"E2E/Del108{origin[0]}-{_uid()}"
    old, new = f"{root}/src", f"{root}/dst"
    notes = {f"{old}/a.md": "# A\n\nalpha 108", f"{old}/b.md": "# B\n\nbeta 108"}
    async with folder_ops.folder_ops_on(cdp_a, cdp_b, write_stop=True):
        rows = _seed(api_sync, (vault_a, vault_b), notes, prefix=root)
        rows = _move(api_sync, root, rows, old, new)
        for vault in (vault_a, vault_b):
            wait_for_content(vault, f"{new}/a.md", "alpha 108")

        decoy = f"{old}/a.md"
        api_sync.create_note(decoy, "# Decoy\n\ndecoy 108")
        for vault in (vault_a, vault_b):
            wait_for_content(vault, decoy, "decoy 108")
        with_decoy, _ = folder_ops.wait_server_paths(api_sync, root, set(rows) | {decoy})
        assert with_decoy[decoy]["id"] != rows[f"{new}/a.md"]["id"], "decoy reused the moved id"

        await cdp_a.arm_vault_spy()
        await cdp_b.arm_vault_spy()
        if origin == "api":
            assert api_sync.delete_note(f"{new}/a.md") in (200, 204)
        else:
            delete_note(vault_a, f"{new}/a.md")
        expected = {decoy, f"{new}/b.md"}
        after, _ = folder_ops.wait_server_paths(api_sync, root, expected)
        assert after[decoy]["id"] == with_decoy[decoy]["id"], "the decoy was replaced"
        for who, vault in (("A", vault_a), ("B", vault_b)):
            wait_for_file_gone(vault, f"{new}/a.md")
            _assert_disk_holds(vault, root, expected, who)
            assert "decoy 108" in (vault / decoy).read_text(encoding="utf-8")
        for who, cdp in (("A", cdp_a), ("B", cdp_b)):
            events = await cdp.disarm_vault_spy()
            hit = folder_ops.events_under(events, f"{old}/", ("delete", "rename", "create"))
            assert not hit, f"{who} touched the decoy at the old path: {hit}"
        api_sync.wait_for_note_content(decoy, "decoy 108")


# -- 5: root-level notes -------------------------------------------------------


@pytest.mark.asyncio
async def test_root_notes_before_and_after_folder_move(
    fresh_instance_pair, resumed_api, resumed_vault_id
):
    """Create, rename, list and delete notes at the vault root, before and
    after a folder elsewhere moves without a cascade (the vault then reads
    every path by name). Runs on the resumed pair's private vault, NOT the
    session vault, which already holds earlier tests' moved folders: "pre"
    must mean a vault with no uncascaded move, and is checked."""
    inst_a, inst_b, cdp_a, cdp_b = fresh_instance_pair
    for cdp in (cdp_a, cdp_b):
        await cdp.wait_for_stream_connected()
    api, vid = resumed_api, resumed_vault_id
    va, vb = inst_a.vault_path, inst_b.vault_path
    uid = _uid()
    stem = f"Root108-{uid}"
    keep = f"{stem}-keep.md"
    async with folder_ops.folder_ops_on(cdp_a, cdp_b, write_stop=True):
        _seed(api, (va, vb), {keep: "# Keep\n\nroot survivor 108"}, prefix=keep)
        assert folder_ops.moved_folder_count(vid) == 0, (
            "precondition: the 'pre' phase needs a vault with no folder moved "
            "without a cascade; an earlier test left one in the resumed vault"
        )
        await _root_cycle(api, vid, va, vb, cdp_a, stem, "pre", {keep})

        mv = f"E2E/RootMv108-{uid}"
        rows = _seed(api, (va, vb), {f"{mv}/src/x.md": "# X\n\nx 108"}, prefix=mv)
        _move(api, mv, rows, f"{mv}/src", f"{mv}/dst")
        assert folder_ops.moved_folder_count(vid) >= 1

        await _root_cycle(api, vid, va, vb, cdp_a, stem, "post", {keep})
        _assert_get_notes(api, vid, [keep])
        for vault in (va, vb):
            wait_for_content(vault, keep, "root survivor 108")


async def _root_cycle(api, vid, vault_a, vault_b, cdp_a, stem, phase, survivors) -> None:
    a, a2, b = f"{stem}-{phase}-a.md", f"{stem}-{phase}-a2.md", f"{stem}-{phase}-b.md"
    write_note(vault_a, a, f"# A\n\n{phase} plugin root 108")
    api.wait_for_note_content(a, f"{phase} plugin root 108")
    api.create_note(b, f"# B\n\n{phase} rest root 108")
    for vault in (vault_a, vault_b):
        wait_for_content(vault, a, f"{phase} plugin root 108")
        wait_for_content(vault, b, f"{phase} rest root 108")
    before, _ = folder_ops.wait_server_paths(api, stem, {*survivors, a, b})

    await cdp_a.rename_file(a, a2)
    after, _ = folder_ops.wait_server_paths(api, stem, {*survivors, a2, b})
    assert after[a2]["id"] == before[a]["id"], f"{phase}: the root rename changed identity"
    live = {*survivors, a2, b}
    mine = {p for p in api.list_folder_paths("") if p.startswith(stem)}
    assert mine == live, f"{phase}: REST root listing {sorted(mine)}"
    mine = {p for p in _mcp_list(api, vid, "")[0] if p.startswith(stem)}
    assert mine == live, f"{phase}: MCP root listing {sorted(mine)}"
    assert _tree(api, stem)[0] == live
    _assert_get_notes(api, vid, sorted(live), gone=[a])
    wait_for_file_gone(vault_b, a)
    wait_for_content(vault_b, a2, f"{phase} plugin root 108")

    api.mcp_tool("delete_note", {"path": b, "vault_id": vid})
    delete_note(vault_a, a2)
    folder_ops.wait_server_paths(api, stem, set(survivors))
    for vault in (vault_a, vault_b):
        for path in (a, a2, b):
            wait_for_file_gone(vault, path)
        for path in survivors:
            assert (vault / path).exists(), f"{phase}: {path} vanished from {vault}"


# -- 6: a chain of moves, read by every surface and a fresh device -----------


@pytest.mark.asyncio
async def test_rename_chain_reads_final_paths_everywhere(
    fresh_instance_pair, resumed_api, resumed_vault_id
):
    """a -> b (REST), b -> c (MCP), then c/sub moved under another parent
    (REST). REST listings, the vault tree, MCP and the live device read only
    the final paths; a device that starts fresh afterwards pulls exactly them."""
    inst_a, inst_b, cdp_a, cdp_b = fresh_instance_pair
    for cdp in (cdp_a, cdp_b):
        await cdp.wait_for_stream_connected()
    api, vid = resumed_api, resumed_vault_id
    root = f"E2E/Chain108-{_uid()}"
    a, b, c, other = (f"{root}/{x}" for x in ("a", "b", "c", "other"))
    notes = {
        f"{a}/n1.md": "# N1\n\nfirst 108",
        f"{a}/sub/n2.md": "# N2\n\nsecond 108",
        f"{other}/o.md": "# O\n\nother 108",
    }
    async with folder_ops.folder_ops_on(cdp_a, cdp_b, write_stop=True):
        rows = _seed(
            api, (inst_a.vault_path, inst_b.vault_path), notes, [f"{a}/sub/img.png"], prefix=root
        )
        rows = _move(api, root, rows, a, b)
        rows = _move(api, root, rows, b, c, via="mcp", vault_id=vid)
        rows = _move(api, root, rows, f"{c}/sub", f"{other}/sub")
        final = {f"{c}/n1.md", f"{other}/sub/n2.md", f"{other}/sub/img.png", f"{other}/o.md"}
        assert set(rows) == final, sorted(rows)
        gone_folders = {a, b, f"{a}/sub", f"{b}/sub", f"{c}/sub"}

        # REST
        assert api.list_folder_paths(c) == {f"{c}/n1.md"}
        assert api.list_folder_paths(f"{other}/sub") == {f"{other}/sub/n2.md"}
        for folder in gone_folders:
            assert api.list_folder_paths(folder) == set(), f"REST still lists {folder}"
        # Web tree
        files, tree_folders = _tree(api, root)
        assert files == final, sorted(files)
        assert {c, other, f"{other}/sub"} <= tree_folders, sorted(tree_folders)
        assert not tree_folders & gone_folders, sorted(tree_folders & gone_folders)
        # MCP
        _, _, mcp_folders = _mcp_list(api, vid, root, recursive=True)
        assert {c, other, f"{other}/sub"} <= mcp_folders, sorted(mcp_folders)
        assert not mcp_folders & gone_folders, sorted(mcp_folders & gone_folders)
        assert _mcp_list(api, vid, f"{other}/sub")[1] == {f"{other}/sub/img.png"}
        live_notes = sorted(p for p in final if p.endswith(".md"))
        _assert_get_notes(
            api, vid, live_notes, gone=[f"{a}/n1.md", f"{b}/n1.md", f"{c}/sub/n2.md"]
        )
        assert _recent_paths(api, vid, folder=root) == set(live_notes)

        # The live device followed every move.
        _assert_disk_holds(inst_a.vault_path, root, final, "live A")
        for folder in (a, b, f"{c}/sub"):
            wait_for_folder_gone(inst_a.vault_path, folder)

        # A device that starts fresh now pulls only the final paths.
        inst_b.stop()
        await inst_b.async_start()
        await cdp_b.wait_for_stream_connected(timeout=DELIVERY_TIMEOUT)
        await cdp_b.trigger_full_sync()
        _assert_disk_holds(inst_b.vault_path, root, final, "fresh B")
        assert (inst_b.vault_path / f"{other}/sub/img.png").read_bytes() == TINY_PNG
        made = [f for f in gone_folders if (inst_b.vault_path / f).exists()]
        assert not made, f"the fresh device made folders that no longer exist: {made}"
        wait_for_content(inst_b.vault_path, f"{c}/n1.md", "first 108")
