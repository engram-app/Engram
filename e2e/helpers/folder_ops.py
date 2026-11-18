"""Shared harness for folder-op e2e tests (test_107 plugin folder ops,
test_108 folders moved without a cascade).

Owns:
  * the stack-global `folder_ops` switch (`folder_ops_on`, `switch_backstop`):
    on, the server sends folder ops to plugins AND (S5 write stop,
    `Engram.Folders.WriteStop`) moves a folder as ONE folder row, leaving the
    notes under it at their old stored path;
  * proof that a move really was uncascaded (`assert_uncascaded`), so a
    test of the S5 read paths can never pass on the cascade instead;
  * the server oracles every folder-op test reads (`wait_server_paths`,
    `folder_paths`, `same_ids`) and the device-side ones (`wait_disk_paths`,
    `events_under`, `assert_spy_saw_rename`, `socket_down`).

Everything is scoped to a caller's per-test path prefix
(docs/context/e2e-session-vault-scoping-trap.md): the session vault holds every
other test's notes.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time
from contextlib import asynccontextmanager
from pathlib import Path

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.cdp import ENGINE_PATH
from helpers.crypto_probe import psql_one
from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import files_under

logger = logging.getLogger(__name__)


# -- the folder_ops switch ----------------------------------------------------


def _lines(out: str) -> set[str]:
    return {line.strip() for line in out.splitlines()}


def _bool_rpc(label: str, elixir_bool: str) -> bool:
    # The node's Logger shares the rpc's stdout, so match a whole line.
    lines = _lines(backend_rpc(f'IO.puts("{label}=#{{{elixir_bool}}}")'))
    assert lines & {f"{label}=true", f"{label}=false"}, f"{label} read failed: {lines}"
    return f"{label}=true" in lines


def switch_reads() -> bool:
    return _bool_rpc("switch", "Engram.Folders.Wire.enabled?()")


def write_stop_on() -> bool:
    """Whether a folder rename right now writes ONE folder row (S5)."""
    return _bool_rpc("write_stop", "Engram.Folders.WriteStop.on?()")


def set_switch(on: bool) -> None:
    expr = (
        'IO.inspect(Engram.ServiceConfig.override(:folder_ops, true, by: "e2e"))'
        if on
        else 'IO.inspect(Engram.ServiceConfig.clear(:folder_ops, by: "e2e"))'
    )
    out = backend_rpc(expr)
    assert ":ok" in _lines(out), f"folder_ops switch write failed: {out!r}"
    assert switch_reads() is on, f"folder_ops switch did not read {on} after setting it"


def switch_backstop():
    """Body of a module-scoped autouse fixture: the switch is a database row,
    so a killed or timed-out run skips every `finally` and would leave it on
    for a reused stack. Clear it before and after the module."""
    set_switch(False)
    yield
    set_switch(False)


async def plugin_folder_ops_enabled(cdp) -> bool:
    return await cdp.evaluate(f"{ENGINE_PATH}.folderOps.enabled() === true") is True


async def rejoin(cdp, want: bool) -> None:
    """Rejoin so the plugin re-reads `features.folder_ops` from the USER join
    reply; wait until the plugin reports `want`."""
    await cdp.disconnect_stream()
    await cdp.reconnect_stream()
    await cdp.wait_for_stream_connected()
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if await plugin_folder_ops_enabled(cdp) is want:
            return
        await asyncio.sleep(0.5)
    raise TimeoutError(f"plugin folderOps.enabled() never became {want} after a rejoin")


async def run_cleanup(body_failed: bool, *steps) -> None:
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
            logger.exception("folder-ops cleanup step %r failed", name)
            first = first or e
    if first is not None and not body_failed:
        raise first


@asynccontextmanager
async def folder_ops_on(*cdps, write_stop: bool = False):
    """Turn the global switch on for one test, restore it even on failure.

    Every device in `cdps` rejoins so it learns the switch. With
    `write_stop`, also wait until the S5 write stop reads on: a test of the
    uncascaded read paths is vacuous on a cascading server.
    """
    workers = os.environ.get("PYTEST_XDIST_WORKER_COUNT", "1")
    if workers != "1":
        pytest.fail(
            f"the folder_ops switch is stack-global; under {workers} xdist workers "
            "flipping it would change every concurrently running test"
        )
    body_failed = False
    try:
        set_switch(True)
        if write_stop:
            wait_write_stop_on()
        for cdp in cdps:
            await rejoin(cdp, True)
        yield
    except BaseException:
        body_failed = True
        raise
    finally:
        await run_cleanup(
            body_failed,
            ("switch off", lambda: set_switch(False)),
            *((f"rejoin {i}", lambda c=c: rejoin(c, False)) for i, c in enumerate(cdps)),
        )


def wait_write_stop_on(timeout: float = 30) -> None:
    deadline = time.monotonic() + timeout
    while not write_stop_on():
        assert time.monotonic() < deadline, (
            "precondition: with folder_ops on, Engram.Folders.WriteStop.on?() never "
            "read true (rollback floor, note_name ledger or fleet readiness), so "
            "folder renames still cascade and no uncascaded read path is exercised"
        )
        time.sleep(1)


# -- server oracles -----------------------------------------------------------


def folder_paths(manifest: dict) -> dict[str, str]:
    """{folder path: folder row id} from the manifest's `folders` rows."""
    rows = {r["id"]: r for r in manifest.get("folders") or []}
    out: dict[str, str] = {}
    for r in rows.values():
        parts, cur = [], r
        for _ in range(64):  # a cycle is a server bug, not a hang
            parts.append(cur["name"])
            cur = rows.get(cur.get("parent_id"))
            if cur is None:
                break
        out["/".join(reversed(parts))] = r["id"]
    return out


def wait_server_paths(api, prefix: str, expected: set[str], timeout=DELIVERY_TIMEOUT):
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


def assert_uncascaded(manifest: dict, folder: str) -> None:
    """The folder row at `folder` was moved WITHOUT a cascade
    (`notes_cascaded = false`): the notes under it still store the old path,
    so every read the caller asserts next goes through the S5 shown-path
    readers, not a cascaded row."""
    ids = folder_paths(manifest)
    assert folder in ids, f"no live folder row at {folder}: {sorted(ids)}"
    fid = ids[folder]
    assert all(c in "0123456789abcdef-" for c in fid), f"odd folder id {fid!r}"
    got = psql_one(
        f"SELECT notes_cascaded FROM folders WHERE id = '{fid}';",
        f"notes_cascaded({folder})",
    )
    assert got == "f", (
        f"precondition: the move to {folder} cascaded (notes_cascaded={got!r}), so "
        "this test would not exercise the uncascaded read paths"
    )


def same_ids(before: dict, after: dict, old: str, new: str, same_content: bool = True) -> None:
    """Every row under `old` kept its id (and content) at its path under `new`."""
    for path, row in before.items():
        moved = after[path.replace(old, new, 1)]
        assert moved["id"] == row["id"], f"{path} changed identity in the move: {row} -> {moved}"
        assert not same_content or moved.get("content_hash") == row.get("content_hash"), (
            f"{path} content changed in the move: {row} -> {moved}"
        )


def moved(paths, old: str, new: str) -> set[str]:
    return {p.replace(old, new, 1) for p in paths}


# -- device oracles -----------------------------------------------------------


def wait_disk_paths(vault: Path, prefix: str, expected: set[str], who: str,
                    timeout=DELIVERY_TIMEOUT) -> None:
    """Poll until the files under `prefix` on a device are EXACTLY `expected`:
    nothing missing, no conflict copy, nothing left at an old path."""
    deadline = time.monotonic() + timeout
    while (got := files_under(vault, prefix)) != expected:
        if time.monotonic() > deadline:
            raise TimeoutError(
                f"{who}'s files under {prefix} never became {sorted(expected)}; "
                f"missing {sorted(expected - got)}, extra {sorted(got - expected)}"
            )
        time.sleep(0.5)


def events_under(events: list[dict], prefix: str, kinds: tuple[str, ...]) -> list[dict]:
    return [
        e
        for e in events
        if e["event"] in kinds
        and (e["path"].startswith(prefix) or (e.get("old") or "").startswith(prefix))
    ]


def assert_spy_saw_rename(events: list[dict], who: str, old: str) -> None:
    """Positive control: the spy recorded the device's own rename, so an
    empty create/delete list is not a dead listener."""
    assert any(e["event"] == "rename" and e.get("old") == old for e in events), (
        f"{who}'s vault spy never saw its own rename of {old}: {events}"
    )


async def wait_folders_known(cdp, *paths: str, teach: bool = False) -> None:
    """Poll until the plugin's folder index holds a server id for every path.

    The plugin only sends a `folder_op` when the folder AND its target parent
    have server ids. A creator learns them from its `crdt_create` replies; a
    peer learns them from a manifest `folders` list, so `teach` runs the
    plugin's own full-manifest id reconcile first.
    """
    if teach:
        await cdp.evaluate(f"{ENGINE_PATH}.reconcileNoteIdMapFromManifest()", await_promise=True)
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


@asynccontextmanager
async def socket_down(cdp, rest_too: bool = False):
    """The crdt socket down (and, with `rest_too`, every REST write failing).
    Restores REST first, then the socket: the order that exercises the
    plugin's hold on REST replays under a pending folder op."""
    await cdp.disconnect_stream()
    if rest_too:
        await cdp.simulate_offline()
    try:
        assert not await cdp.check_stream_connected(), "disconnect_stream() must drop the channel"
        yield
    finally:
        if rest_too:
            await cdp.restore_online()
        await cdp.reconnect_stream()
