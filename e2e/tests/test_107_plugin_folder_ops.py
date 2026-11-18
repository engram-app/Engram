"""Test 107: plugin folder ops (Engram#2523 S4, Engram-obsidian#689) in real Obsidian.

With the server's `folder_ops` switch on, a folder rename in Obsidian is ONE
`folder_op` on the crdt socket: no per-note `crdt_create` relocation, no
attachment re-upload, and the peer follows with one `vault.rename`. The plugin's
simulator proves this against a model server; this module proves it against
the real backend and two real Obsidian instances, plus the plugin attachment
rename (`POST /attachments/rename`, unflagged) and the per-file fallback.

Oracles (all scoped to a per-test uuid prefix, see
docs/context/e2e-session-vault-scoping-trap.md):
  * `route_probe` counts what reached the server, armed AFTER setup. Every
    test that asserts a zero first proves the same counter counts (a positive
    control during setup), so a 0 is never vacuous.
  * The sync manifest: the exact set of live paths under the prefix (new
    paths present, old gone, nothing duplicated), note ids, content hashes and
    the live folder rows.
  * `cdp.arm_vault_spy`: the create/delete/rename events Obsidian fired. A
    trash-then-redownload converges on disk and is only visible here.

The switch is GLOBAL to the stack, so `folder_ops.folder_ops_on` flips it for one test
and restores it in `finally`, and refuses to run under more than one xdist
worker (e2e-clerk runs the suite serially, `-n 1`).

Plugin folder ops (Engram-obsidian#689) are on plugin main, so every case
asserts them unconditionally: a plugin that loses `folderOps` or
`renameAttachment` fails here, it never skips (the contract step of
../engram-workspace/docs/context/oauth-e2e-pairing-and-token-binding.md).

Not covered here: plugins 1.35.0 / 1.39.2 by version (the harness builds the
plugin from source, so "old plugin" is plugin main), and mobile event order
(manual check, R4 on Engram#2523).
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid

import pytest

from helpers import folder_ops
from helpers.cdp import PLUGIN_PATH
from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import wait_for_binary_delivery, wait_for_delivery
from helpers.route_probe import arm_routes, read_routes
from helpers.vault import (
    TINY_PNG,
    wait_for_content,
    wait_for_file_gone,
    wait_for_folder_gone,
    write_binary,
    write_note,
)

logger = logging.getLogger(__name__)


_backstop = pytest.fixture(scope="module", autouse=True)(folder_ops.switch_backstop)


def _layout(suffix: str, tag: str):
    root = f"E2E/{tag}107-{suffix}"
    return root, f"{root}-done"


async def _seed_folder(vault_a, vault_b, api, root: str, with_attachment: bool) -> dict:
    """A creates `a.md`, `sub/b.md` (and `img.png`); server and B converge.
    Positive control: the counters see the creates. Returns server rows."""
    files = {f"{root}/a.md": "# A\n\nalpha 107", f"{root}/sub/b.md": "# B\n\nbeta 107"}
    arm_routes(root)
    for path, body in files.items():
        write_note(vault_a, path, body)
    expected = set(files)
    if with_attachment:
        write_binary(vault_a, f"{root}/img.png", TINY_PNG)
        expected.add(f"{root}/img.png")
    rows, _ = folder_ops.wait_server_paths(api, root, expected)
    seeded = read_routes()
    assert seeded.crdt_create >= len(files), f"create counter saw nothing: {seeded}"
    if with_attachment:
        assert seeded.attachment_upload >= 1, f"upload counter saw nothing: {seeded}"
        wait_for_binary_delivery(vault_b, f"{root}/img.png", api)
    for path in files:
        wait_for_delivery(vault_b, path, api)
    return rows


# -- A: plugin attachment rename (unflagged) ---------------------------------


@pytest.mark.asyncio
@pytest.mark.parametrize("switch", ["off", "on"])
async def test_plugin_attachment_rename_moves_the_row(
    switch, vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """A renames an attachment: one POST /attachments/rename, no re-upload."""
    root = f"E2E/Att107-{uuid.uuid4().hex[:12]}"
    old, new = f"{root}/img.png", f"{root}/img2.png"

    async def body():
        arm_routes(root)
        write_binary(vault_a, old, TINY_PNG)
        rows, _ = folder_ops.wait_server_paths(api_sync, root, {old})
        assert read_routes().attachment_upload >= 1, "upload counter saw nothing"
        wait_for_binary_delivery(vault_b, old, api_sync)

        arm_routes(root)
        await cdp_a.arm_vault_spy()
        await cdp_a.rename_file(old, new)
        after, _ = folder_ops.wait_server_paths(api_sync, root, {new})
        assert wait_for_binary_delivery(vault_b, new, api_sync) == TINY_PNG
        wait_for_file_gone(vault_b, old)

        routes = read_routes()
        logger.info("test_107 attachment rename (%s): %s", switch, routes)
        assert routes.attachment_rename == 1, (
            f"want one POST /attachments/rename: {routes}"
        )
        assert routes.attachment_upload == 0, (
            f"the rename re-uploaded the bytes: {routes}"
        )
        assert after[new]["id"] == rows[old]["id"], "the move must keep the row's id"
        assert after[new].get("content_hash") == rows[old].get("content_hash")
        a_events = await cdp_a.disarm_vault_spy()
        folder_ops.assert_spy_saw_rename(a_events, "A", old)
        stray = folder_ops.events_under(a_events, root, ("create", "delete"))
        assert not stray, (
            f"A trashed or re-created files around its own rename: {stray}"
        )

    if switch == "on":
        async with folder_ops.folder_ops_on(cdp_a, cdp_b):
            await body()
    else:
        await body()


# -- B: folder rename with a subfolder and an attachment ---------------------


@pytest.mark.asyncio
async def test_plugin_folder_rename_is_one_folder_op(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Flag on: ONE folder_op, nothing per file, ids kept, B follows in one rename."""
    old, new = _layout(uuid.uuid4().hex[:12], "F")
    async with folder_ops.folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(vault_a, vault_b, api_sync, old, with_attachment=True)
        await folder_ops.wait_folders_known(cdp_a, old, "E2E")
        await folder_ops.wait_folders_known(cdp_b, old, "E2E", teach=True)

        arm_routes(old)
        await cdp_a.arm_vault_spy()
        await cdp_b.arm_vault_spy()
        await cdp_a.rename_file(old, new)

        after, manifest = folder_ops.wait_server_paths(api_sync, old, folder_ops.moved(rows, old, new))
        for path in rows:
            moved = path.replace(old, new, 1)
            if path.endswith(".md"):
                wait_for_content(vault_b, moved, "107")
            else:
                assert wait_for_binary_delivery(vault_b, moved, api_sync) == TINY_PNG
        wait_for_folder_gone(vault_b, old)
        wait_for_folder_gone(vault_a, old)

        routes = read_routes()
        logger.info("test_107 folder rename (flag on): %s", routes)
        assert routes.folder_op == 1, f"want exactly 1 folder_op: {routes}"
        assert routes.crdt_create == 0, f"children were re-pushed per note: {routes}"
        assert routes.rest_upsert == 0, f"children were re-pushed over REST: {routes}"
        assert routes.attachment_upload == 0, (
            f"the attachment was re-uploaded: {routes}"
        )
        assert routes.attachment_rename == 0, f"the attachment moved per file: {routes}"
        folder_ops.same_ids(rows, after, old, new)
        folders = folder_ops.folder_paths(manifest)
        assert new in folders and old not in folders, (
            f"server folders: {sorted(folders)}"
        )

        a_events = await cdp_a.disarm_vault_spy()
        b_events = await cdp_b.disarm_vault_spy()
        folder_ops.assert_spy_saw_rename(a_events, "A", old)
        for who, events in (("A", a_events), ("B", b_events)):
            stray = folder_ops.events_under(events, old, ("create", "delete"))
            assert not stray, (
                f"{who} trashed or re-downloaded files in the move: {stray}"
            )
        assert any(e["event"] == "rename" and e.get("old") == old for e in b_events), (
            f"B never renamed the folder itself (per-file convergence?): {b_events}"
        )


# -- E: per-file fallback and old plugins (never skipped) --------------------


@pytest.mark.asyncio
async def test_folder_rename_flag_off_falls_back_per_file(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Flag off: no folder_op, notes relocate per file, same end state."""
    assert folder_ops.switch_reads() is False, "precondition: the folder_ops switch must be off"
    old, new = _layout(uuid.uuid4().hex[:12], "Off")
    rows = await _seed_folder(vault_a, vault_b, api_sync, old, with_attachment=True)

    arm_routes(old)
    await cdp_a.rename_file(old, new)
    after, _ = folder_ops.wait_server_paths(api_sync, old, folder_ops.moved(rows, old, new))
    for path in rows:
        moved = path.replace(old, new, 1)
        if path.endswith(".md"):
            wait_for_content(vault_b, moved, "107")
        else:
            assert wait_for_binary_delivery(vault_b, moved, api_sync) == TINY_PNG
    # Files, not the folder: the per-file path can leave the emptied folder
    # on the peer (test_34 asserts files only too); measured at plugin a1029bdd.
    for path in rows:
        wait_for_file_gone(vault_b, path)

    routes = read_routes()
    logger.info("test_107 folder rename (flag off): %s", routes)
    assert routes.folder_op == 0, f"a folder_op went to a flag-off server: {routes}"
    assert routes.crdt_create >= 2, f"the two notes did not relocate per file: {routes}"
    for path in rows:
        if path.endswith(".md"):
            moved = after[path.replace(old, new, 1)]
            assert moved["id"] == rows[path]["id"], f"{path} changed identity: {moved}"
    # The per-file attachment leg is a move, never a delete plus re-upload.
    assert routes.attachment_rename == 1 and routes.attachment_upload == 0, (
        f"the attachment was re-uploaded instead of moved: {routes}"
    )


@pytest.mark.asyncio
async def test_api_folder_rename_converges_with_flag_on(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Flag on, folder renamed on the web/API: both devices converge, nothing lost.

    The inbound `folder_changed` path: both devices follow with one
    `vault.rename`, so the emptied old folder is gone too.
    """
    old, new = _layout(uuid.uuid4().hex[:12], "Api")
    async with folder_ops.folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(vault_a, vault_b, api_sync, old, with_attachment=True)
        assert api_sync.rename_folder(old, new) == 200
        after, _ = folder_ops.wait_server_paths(api_sync, old, folder_ops.moved(rows, old, new))
        folder_ops.same_ids(rows, after, old, new)
        for vault in (vault_a, vault_b):
            for path in rows:
                moved = path.replace(old, new, 1)
                if path.endswith(".md"):
                    wait_for_content(vault, moved, "107")
                else:
                    assert wait_for_binary_delivery(vault, moved, api_sync) == TINY_PNG
                wait_for_file_gone(vault, path)
            wait_for_folder_gone(vault, old)


# -- C: offline create / edit + offline folder rename ------------------------


async def _wait_queued(cdp, path: str) -> None:
    deadline = time.monotonic() + 20
    ops: list = []
    while time.monotonic() < deadline:
        ops = await cdp.get_crdt_queue_ops()
        if any(o.get("path") == path for o in ops):
            return
        await asyncio.sleep(0.5)
    raise AssertionError(
        f"precondition: the offline create of {path} must be queued: {ops}"
    )


async def _wait_edit_held(cdp, path: str) -> None:
    """Poll until an offline edit of `path` sits in either outbound queue (the
    REST offline queue or the CRDT op queue, whichever the plugin chose)."""
    deadline = time.monotonic() + 20
    rest: list = []
    crdt: list = []
    while time.monotonic() < deadline:
        rest = await cdp.get_queue_entries()
        crdt = await cdp.get_crdt_queue_ops()
        if any(o.get("path") == path for o in rest + crdt):
            return
        await asyncio.sleep(0.5)
    raise AssertionError(
        f"precondition: the offline edit of {path} must be queued before the rename; "
        f"offline queue={rest}, crdt queue={crdt}"
    )


@pytest.mark.asyncio
@pytest.mark.parametrize("order", ["create_then_rename", "rename_then_create"])
async def test_offline_create_and_folder_rename_converge(
    order, vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Offline create + offline folder rename: one op + one create, no strays.

    `rename_then_create` was red at plugin 26f90b7 as 1 op + 4 creates: the
    create made the server mint a second folder row at the target and the op
    was refused `conflict` (round-5 HIGH-1 / MEDIUM-3 on #689).
    """
    old, new = _layout(uuid.uuid4().hex[:12], "Off" + order[0].upper())
    async with folder_ops.folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(
            vault_a, vault_b, api_sync, old, with_attachment=False
        )
        await folder_ops.wait_folders_known(cdp_a, old, "E2E")
        # Setup starts converged on both devices; B lacking the folder is a
        # separate plugin bug, covered by the plugin fix.
        await folder_ops.wait_folders_known(cdp_b, old, "E2E", teach=True)

        arm_routes(old)
        await cdp_a.arm_vault_spy()
        async with folder_ops.socket_down(cdp_a):
            if order == "create_then_rename":
                write_note(vault_a, f"{old}/new.md", "# New\n\nmade offline 107")
                await _wait_queued(cdp_a, f"{old}/new.md")
                await cdp_a.rename_file(old, new)
            else:
                await cdp_a.rename_file(old, new)
                write_note(vault_a, f"{new}/new.md", "# New\n\nmade offline 107")
                await _wait_queued(cdp_a, f"{new}/new.md")
        await cdp_a.wait_for_crdt_queue_drain(timeout=45)

        expected = folder_ops.moved(rows, old, new) | {f"{new}/new.md"}
        after, manifest = folder_ops.wait_server_paths(api_sync, old, expected)
        folder_ops.same_ids(rows, after, old, new)
        for path in expected:
            wait_for_content(vault_b, path, "107")
        wait_for_folder_gone(vault_b, old)
        wait_for_folder_gone(vault_a, old)

        routes = read_routes()
        logger.info("test_107 offline %s: %s", order, routes)
        assert routes.folder_op == 1, f"want exactly 1 folder_op: {routes}"
        assert routes.crdt_create == 1, f"want exactly the new note's create: {routes}"
        assert routes.rest_upsert == 0, f"notes went over REST: {routes}"
        folders = folder_ops.folder_paths(manifest)
        assert old not in folders, f"the old folder row survived: {sorted(folders)}"
        a_events = await cdp_a.disarm_vault_spy()
        folder_ops.assert_spy_saw_rename(a_events, "A", old)
        stray = folder_ops.events_under(a_events, old, ("delete",))
        assert not stray, f"A trashed files around its offline rename: {stray}"


@pytest.mark.asyncio
async def test_offline_edit_then_folder_rename_lands_at_new_path(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Offline edit of a child + offline folder rename: the edit lands at the
    new path, one note, no 409 drop (the replay hold on #689)."""
    old, new = _layout(uuid.uuid4().hex[:12], "Edit")
    async with folder_ops.folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(
            vault_a, vault_b, api_sync, old, with_attachment=False
        )
        await folder_ops.wait_folders_known(cdp_a, old, "E2E")
        # Setup starts converged on both devices; B lacking the folder is a
        # separate plugin bug, covered by the plugin fix.
        await folder_ops.wait_folders_known(cdp_b, old, "E2E", teach=True)
        marker = f"offline edit {uuid.uuid4().hex[:8]}"

        arm_routes(old)
        async with folder_ops.socket_down(cdp_a, rest_too=True):
            write_note(vault_a, f"{old}/a.md", f"# A\n\nalpha 107\n\n{marker}\n")
            # The edit must be HELD before the rename, or this covers the
            # other order (rename, then edit at the new path) and the replay
            # hold goes unchecked.
            await _wait_edit_held(cdp_a, f"{old}/a.md")
            await cdp_a.rename_file(old, new)

        after, _ = folder_ops.wait_server_paths(api_sync, old, folder_ops.moved(rows, old, new))
        api_sync.wait_for_note_content(f"{new}/a.md", marker)
        assert after[f"{new}/a.md"]["id"] == rows[f"{old}/a.md"]["id"], (
            "the edit forked the note"
        )
        wait_for_content(vault_b, f"{new}/a.md", marker)
        wait_for_folder_gone(vault_b, old)
        routes = read_routes()
        logger.info("test_107 offline edit + rename: %s", routes)
        assert routes.folder_op == 1, f"want exactly 1 folder_op: {routes}"


# -- D: restart mid-op ---------------------------------------------------------


@pytest.mark.asyncio
async def test_restart_with_folder_op_pending(
    obsidian_a, vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """A's op is pending (never sent) when the plugin reloads; B edits a child
    meanwhile. The op survives in data.json, is sent after the reload, A's
    files never move back, B's edit lands at the new path, one note per id
    (round-5 MEDIUM-4 on #689)."""
    old, new = _layout(uuid.uuid4().hex[:12], "Rst")
    async with folder_ops.folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(
            vault_a, vault_b, api_sync, old, with_attachment=False
        )
        await folder_ops.wait_folders_known(cdp_a, old, "E2E")
        # Setup starts converged on both devices; B lacking the folder is a
        # separate plugin bug, covered by the plugin fix.
        await folder_ops.wait_folders_known(cdp_b, old, "E2E", teach=True)
        marker = f"peer edit {uuid.uuid4().hex[:8]}"

        arm_routes(old)
        # Hold the op on this channel instance: "held" = never sent, spends no
        # attempt. The reload builds a new channel, which drops the override
        # and replays the persisted op (still flag-on here, so it is acked).
        # Any failure before the reload reloads anyway: the stub and the
        # pending op must never outlive this test on the session's device A.
        await cdp_a.evaluate(
            f"{PLUGIN_PATH}.noteStream.folderOp = async () => ({{ kind: 'held' }}); true"
        )
        try:
            await cdp_a.rename_file(old, new)
            await cdp_a.persist_plugin_data()
            pending = obsidian_a.read_data_json().get("folderOps") or []
            assert any(o.get("to") == new for o in pending), (
                "precondition: the pending op must be persisted, "
                f"data.json folderOps={pending}"
            )

            # B edits a child at the path the server still has.
            write_note(vault_b, f"{old}/a.md", f"# A\n\nalpha 107\n\n{marker}\n")
            api_sync.wait_for_note_content(f"{old}/a.md", marker)

            # Attribution: a move-back BEFORE the reload is the pending-op
            # fence, not the restart.
            back = [p for p in rows if (vault_a / p).exists()]
            assert not back, (
                f"A moved files back before the reload (op pending): {back}"
            )
        except BaseException:
            await folder_ops.run_cleanup(True, ("reload A", cdp_a.reload_plugin))
            raise

        await cdp_a.reload_plugin()

        # Sample A's disk through the reload, the send and its ack: the old
        # paths must never come back.
        old_files = [vault_a / p for p in rows]
        expected = folder_ops.moved(rows, old, new)
        deadline = time.monotonic() + DELIVERY_TIMEOUT
        settled_at = None
        while True:
            back = [str(f) for f in old_files if f.exists()]
            assert not back, (
                f"A moved files back to the old folder after the reload: {back}"
            )
            if settled_at is None:
                notes = api_sync.get_manifest().get("notes") or []
                live = {r["path"] for r in notes if r["path"].startswith(old)}
                if live == expected:
                    settled_at = time.monotonic()
            elif time.monotonic() - settled_at > 15:
                break
            assert time.monotonic() < deadline, f"server never moved {old} -> {new}"
            await asyncio.sleep(1)

        after, _ = folder_ops.wait_server_paths(api_sync, old, expected)
        folder_ops.same_ids(rows, after, old, new, same_content=False)  # B edited a.md
        api_sync.wait_for_note_content(f"{new}/a.md", marker)
        wait_for_content(vault_a, f"{new}/a.md", marker)
        wait_for_content(vault_b, f"{new}/a.md", marker)
        wait_for_folder_gone(vault_b, old)

        routes = read_routes()
        logger.info("test_107 restart mid-op: %s", routes)
        assert routes.folder_op == 1, (
            f"want exactly 1 folder_op (the persisted op, sent once): {routes}"
        )
        assert routes.crdt_create == 0, (
            f"the restart re-pushed children per note: {routes}"
        )
