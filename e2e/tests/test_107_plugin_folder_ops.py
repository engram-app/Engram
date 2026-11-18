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

The switch is GLOBAL to the stack, so `_folder_ops_on` flips it for one test
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
import json
import logging
import os
import time
import uuid
from contextlib import asynccontextmanager

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.cdp import ENGINE_PATH, PLUGIN_PATH
from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import wait_for_binary_delivery, wait_for_delivery
from helpers.route_probe import arm_routes, read_routes
from helpers.vault import (
    wait_for_content,
    wait_for_file_gone,
    wait_for_folder_gone,
    write_binary,
    write_note,
)

logger = logging.getLogger(__name__)

# Minimal valid PNG: 1x1 red pixel (test_33's constant).
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)

# -- the folder_ops switch ----------------------------------------------------


def _set_switch(on: bool) -> None:
    expr = (
        'IO.inspect(Engram.ServiceConfig.override(:folder_ops, true, by: "e2e"))'
        if on
        else 'IO.inspect(Engram.ServiceConfig.clear(:folder_ops, by: "e2e"))'
    )
    # The node's Logger shares the rpc's stdout (the override logs a warning
    # line after `:ok`), so match a whole line rather than the last one.
    out = backend_rpc(expr)
    assert ":ok" in _lines(out), f"folder_ops switch write failed: {out!r}"
    assert _switch_reads() is on, (
        f"folder_ops switch did not read {on} after setting it"
    )


def _lines(out: str) -> set[str]:
    return {line.strip() for line in out.splitlines()}


def _switch_reads() -> bool:
    lines = _lines(backend_rpc('IO.puts("switch=#{Engram.Folders.Wire.enabled?()}")'))
    assert lines & {"switch=true", "switch=false"}, f"switch read failed: {lines}"
    return "switch=true" in lines


async def _plugin_folder_ops_enabled(cdp) -> bool:
    return await cdp.evaluate(f"{ENGINE_PATH}.folderOps.enabled() === true") is True


async def _rejoin(cdp, want: bool) -> None:
    """Rejoin so the plugin re-reads `features.folder_ops` from the USER join
    reply; with `want`, wait until the plugin reports it."""
    await cdp.disconnect_stream()
    await cdp.reconnect_stream()
    await cdp.wait_for_stream_connected()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if await _plugin_folder_ops_enabled(cdp) is want:
            return
        await asyncio.sleep(0.5)
    raise TimeoutError(f"plugin folderOps.enabled() never became {want} after a rejoin")


@asynccontextmanager
async def _folder_ops_on(cdp_a, cdp_b):
    """Turn the global switch on for one test, restore it even on failure."""
    workers = os.environ.get("PYTEST_XDIST_WORKER_COUNT", "1")
    if workers != "1":
        pytest.fail(
            f"test_107 flips the stack-global folder_ops switch; under {workers} xdist "
            "workers it would change every concurrently running test"
        )
    body_failed = False
    try:
        _set_switch(True)
        for cdp in (cdp_a, cdp_b):
            await _rejoin(cdp, True)
        yield
    except BaseException:
        body_failed = True
        raise
    finally:
        await _cleanup(
            body_failed,
            ("switch off", lambda: _set_switch(False)),
            ("rejoin A", lambda: _rejoin(cdp_a, False)),
            ("rejoin B", lambda: _rejoin(cdp_b, False)),
        )


async def _cleanup(body_failed: bool, *steps) -> None:
    """Run every cleanup step even when one fails. A failure is logged; the
    first one is raised only when the test body passed, so a cleanup error
    never replaces the test's own failure in the report."""
    first: BaseException | None = None
    for name, step in steps:
        try:
            result = step()
            if asyncio.iscoroutine(result):
                await result
        except Exception as e:  # noqa: BLE001 - every step must run
            logger.exception("test_107 cleanup step %r failed", name)
            first = first or e
    if first is not None and not body_failed:
        raise first


@pytest.fixture(scope="module", autouse=True)
def _folder_ops_off_around_module():
    """Backstop: the switch is a database row, so a killed or timed-out run
    skips every `finally` and would leave it on for a reused stack. Clear it
    before and after the module."""
    _set_switch(False)
    yield
    _set_switch(False)


async def _wait_folders_known(cdp, *paths: str, teach: bool = False) -> None:
    """Poll until the plugin's folder index holds a server id for every path.

    The plugin only sends a `folder_op` when the folder AND its target parent
    have server ids. A creator learns them from its `crdt_create` replies; a
    peer learns them from a manifest `folders` list, so `teach` runs the
    plugin's own full-manifest id reconcile first.
    """
    if teach:
        await cdp.evaluate(
            f"{ENGINE_PATH}.reconcileNoteIdMapFromManifest()", await_promise=True
        )
    js = (
        f"(() => {{ const i = {ENGINE_PATH}.folderOps.index; "
        f"return {json.dumps(list(paths))}.every(p => typeof i.idFor(p) === 'string'); }})()"
    )
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if await cdp.evaluate(js) is True:
            return
        await asyncio.sleep(0.5)
    raise TimeoutError(f"plugin folder index never learned server ids for {paths}")


# -- server oracles -----------------------------------------------------------


def _folder_paths(manifest: dict) -> set[str]:
    rows = {r["id"]: r for r in manifest.get("folders") or []}
    out = set()
    for r in rows.values():
        parts, cur = [], r
        for _ in range(64):  # a cycle is a server bug, not a hang
            parts.append(cur["name"])
            cur = rows.get(cur.get("parent_id"))
            if cur is None:
                break
        out.add("/".join(reversed(parts)))
    return out


def _wait_server_paths(api, prefix: str, expected: set[str], timeout=DELIVERY_TIMEOUT):
    """Poll the manifest until its live notes+attachments under `prefix` are
    EXACTLY `expected`. Returns ({path: row}, manifest)."""
    deadline = time.monotonic() + timeout
    rows: dict = {}
    while True:
        manifest = api.get_manifest()
        rows = {
            r["path"]: r
            for r in (manifest.get("notes") or []) + (manifest.get("attachments") or [])
            if r["path"].startswith(prefix)
        }
        if set(rows) == expected:
            return rows, manifest
        if time.monotonic() > deadline:
            raise TimeoutError(
                f"server paths under {prefix} never became {sorted(expected)}; "
                f"last: {sorted(rows)}"
            )
        time.sleep(0.5)


def _events_under(
    events: list[dict], prefix: str, kinds: tuple[str, ...]
) -> list[dict]:
    return [
        e
        for e in events
        if e["event"] in kinds
        and (e["path"].startswith(prefix) or (e.get("old") or "").startswith(prefix))
    ]


def _assert_spy_saw_rename(events: list[dict], who: str, old: str) -> None:
    """Positive control: the spy recorded the device's own rename, so an
    empty create/delete list is not a dead listener."""
    assert any(e["event"] == "rename" and e.get("old") == old for e in events), (
        f"{who}'s vault spy never saw its own rename of {old}: {events}"
    )


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
    rows, _ = _wait_server_paths(api, root, expected)
    seeded = read_routes()
    assert seeded.crdt_create >= len(files), f"create counter saw nothing: {seeded}"
    if with_attachment:
        assert seeded.attachment_upload >= 1, f"upload counter saw nothing: {seeded}"
        wait_for_binary_delivery(vault_b, f"{root}/img.png", api)
    for path in files:
        wait_for_delivery(vault_b, path, api)
    return rows


def _moved(rows: dict, old: str, new: str) -> set[str]:
    return {p.replace(old, new, 1) for p in rows}


def _assert_same_ids(
    before: dict, after: dict, old: str, new: str, same_content: bool = True
) -> None:
    for path, row in before.items():
        moved = after[path.replace(old, new, 1)]
        assert moved["id"] == row["id"], (
            f"{path} changed identity in the move: {row} -> {moved}"
        )
        assert not same_content or moved.get("content_hash") == row.get(
            "content_hash"
        ), f"{path} content changed in the move: {row} -> {moved}"


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
        rows, _ = _wait_server_paths(api_sync, root, {old})
        assert read_routes().attachment_upload >= 1, "upload counter saw nothing"
        wait_for_binary_delivery(vault_b, old, api_sync)

        arm_routes(root)
        await cdp_a.arm_vault_spy()
        await cdp_a.rename_file(old, new)
        after, _ = _wait_server_paths(api_sync, root, {new})
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
        _assert_spy_saw_rename(a_events, "A", old)
        stray = _events_under(a_events, root, ("create", "delete"))
        assert not stray, (
            f"A trashed or re-created files around its own rename: {stray}"
        )

    if switch == "on":
        async with _folder_ops_on(cdp_a, cdp_b):
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
    async with _folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(vault_a, vault_b, api_sync, old, with_attachment=True)
        await _wait_folders_known(cdp_a, old, "E2E")
        await _wait_folders_known(cdp_b, old, "E2E", teach=True)

        arm_routes(old)
        await cdp_a.arm_vault_spy()
        await cdp_b.arm_vault_spy()
        await cdp_a.rename_file(old, new)

        after, manifest = _wait_server_paths(api_sync, old, _moved(rows, old, new))
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
        _assert_same_ids(rows, after, old, new)
        folders = _folder_paths(manifest)
        assert new in folders and old not in folders, (
            f"server folders: {sorted(folders)}"
        )

        a_events = await cdp_a.disarm_vault_spy()
        b_events = await cdp_b.disarm_vault_spy()
        _assert_spy_saw_rename(a_events, "A", old)
        for who, events in (("A", a_events), ("B", b_events)):
            stray = _events_under(events, old, ("create", "delete"))
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
    assert _switch_reads() is False, "precondition: the folder_ops switch must be off"
    old, new = _layout(uuid.uuid4().hex[:12], "Off")
    rows = await _seed_folder(vault_a, vault_b, api_sync, old, with_attachment=True)

    arm_routes(old)
    await cdp_a.rename_file(old, new)
    after, _ = _wait_server_paths(api_sync, old, _moved(rows, old, new))
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
    async with _folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(vault_a, vault_b, api_sync, old, with_attachment=True)
        assert api_sync.rename_folder(old, new) == 200
        after, _ = _wait_server_paths(api_sync, old, _moved(rows, old, new))
        _assert_same_ids(rows, after, old, new)
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


@asynccontextmanager
async def _socket_down(cdp, rest_too: bool = False):
    """The crdt socket down (and, with `rest_too`, every REST write failing).
    Restores REST first, then the socket: the order that exercises the
    plugin's hold on REST replays under a pending folder op."""
    await cdp.disconnect_stream()
    if rest_too:
        await cdp.simulate_offline()
    try:
        assert not await cdp.check_stream_connected(), (
            "disconnect_stream() must drop the channel"
        )
        yield
    finally:
        if rest_too:
            await cdp.restore_online()
        await cdp.reconnect_stream()


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
    async with _folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(
            vault_a, vault_b, api_sync, old, with_attachment=False
        )
        await _wait_folders_known(cdp_a, old, "E2E")
        # Setup starts converged on both devices; B lacking the folder is a
        # separate plugin bug, covered by the plugin fix.
        await _wait_folders_known(cdp_b, old, "E2E", teach=True)

        arm_routes(old)
        await cdp_a.arm_vault_spy()
        async with _socket_down(cdp_a):
            if order == "create_then_rename":
                write_note(vault_a, f"{old}/new.md", "# New\n\nmade offline 107")
                await _wait_queued(cdp_a, f"{old}/new.md")
                await cdp_a.rename_file(old, new)
            else:
                await cdp_a.rename_file(old, new)
                write_note(vault_a, f"{new}/new.md", "# New\n\nmade offline 107")
                await _wait_queued(cdp_a, f"{new}/new.md")
        await cdp_a.wait_for_crdt_queue_drain(timeout=45)

        expected = _moved(rows, old, new) | {f"{new}/new.md"}
        after, manifest = _wait_server_paths(api_sync, old, expected)
        _assert_same_ids(rows, after, old, new)
        for path in expected:
            wait_for_content(vault_b, path, "107")
        wait_for_folder_gone(vault_b, old)
        wait_for_folder_gone(vault_a, old)

        routes = read_routes()
        logger.info("test_107 offline %s: %s", order, routes)
        assert routes.folder_op == 1, f"want exactly 1 folder_op: {routes}"
        assert routes.crdt_create == 1, f"want exactly the new note's create: {routes}"
        assert routes.rest_upsert == 0, f"notes went over REST: {routes}"
        folders = _folder_paths(manifest)
        assert old not in folders, f"the old folder row survived: {sorted(folders)}"
        a_events = await cdp_a.disarm_vault_spy()
        _assert_spy_saw_rename(a_events, "A", old)
        stray = _events_under(a_events, old, ("delete",))
        assert not stray, f"A trashed files around its offline rename: {stray}"


@pytest.mark.asyncio
async def test_offline_edit_then_folder_rename_lands_at_new_path(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Offline edit of a child + offline folder rename: the edit lands at the
    new path, one note, no 409 drop (the replay hold on #689)."""
    old, new = _layout(uuid.uuid4().hex[:12], "Edit")
    async with _folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(
            vault_a, vault_b, api_sync, old, with_attachment=False
        )
        await _wait_folders_known(cdp_a, old, "E2E")
        # Setup starts converged on both devices; B lacking the folder is a
        # separate plugin bug, covered by the plugin fix.
        await _wait_folders_known(cdp_b, old, "E2E", teach=True)
        marker = f"offline edit {uuid.uuid4().hex[:8]}"

        arm_routes(old)
        async with _socket_down(cdp_a, rest_too=True):
            write_note(vault_a, f"{old}/a.md", f"# A\n\nalpha 107\n\n{marker}\n")
            # The edit must be HELD before the rename, or this covers the
            # other order (rename, then edit at the new path) and the replay
            # hold goes unchecked.
            await _wait_edit_held(cdp_a, f"{old}/a.md")
            await cdp_a.rename_file(old, new)

        after, _ = _wait_server_paths(api_sync, old, _moved(rows, old, new))
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
    async with _folder_ops_on(cdp_a, cdp_b):
        rows = await _seed_folder(
            vault_a, vault_b, api_sync, old, with_attachment=False
        )
        await _wait_folders_known(cdp_a, old, "E2E")
        # Setup starts converged on both devices; B lacking the folder is a
        # separate plugin bug, covered by the plugin fix.
        await _wait_folders_known(cdp_b, old, "E2E", teach=True)
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
            await _cleanup(True, ("reload A", cdp_a.reload_plugin))
            raise

        await cdp_a.reload_plugin()

        # Sample A's disk through the reload, the send and its ack: the old
        # paths must never come back.
        old_files = [vault_a / p for p in rows]
        expected = _moved(rows, old, new)
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

        after, _ = _wait_server_paths(api_sync, old, expected)
        _assert_same_ids(rows, after, old, new, same_content=False)  # B edited a.md
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
