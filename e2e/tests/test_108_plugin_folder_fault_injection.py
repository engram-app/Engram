"""Test 108: plugin folder and first-sync-preview failure paths in real Obsidian.

Plugin PR Engram-obsidian#704 fixes four failure paths that, until now, were
proven only by stubbed unit tests. This module drives each one against the real
backend and a real Obsidian, injecting the fault where a real network or server
would (`helpers/fault_injection.py`), and asserts the plugin's own recovery.

  1. A folder delete whose server DELETE fails must not let the next pull
     resurrect the folder; the pull retries the delete instead.
  2. `POST /folders` answered 429 + Retry-After must stop the plugin re-POSTing
     every untracked folder on every catch-up.
  3. A first-sync preview whose `crdt:` join the backend refuses must say why
     (typed reason, fast), not blame "your connection".
  4. Empty-name folder paths ('' and 'a//') must never create a folder.

Oracles that cannot lie: the wrapper's own hit log (a "nothing happened"
assertion is only trusted after the wrapper is proven to have fired), the real
server's marker list, and the vault. Every path is scoped to a per-test uuid
(docs/context/e2e-session-vault-scoping-trap.md: the vault is session-wide).

Tests 1-3 fail on a plugin without #704 (that is the point); test 4 is a guard
that is only meaningful alongside them.

Not covered: mobile emulation (Android event order and `requestUrl` quirks).
There is no mobile emulation in this harness; that is a separate follow-up.
"""

from __future__ import annotations

import asyncio
import json
import math
import time
import uuid

import pytest

from helpers.cdp import ENGINE_PATH
from helpers.fault_injection import (
    api_fault,
    crdt_join_downgrade,
    read_api_fault,
    release_api_fault,
)
from helpers.latency import DELIVERY_TIMEOUT


async def _wait_until(pred, timeout: float, what: str, poll: float = 0.3):
    """Poll a sync or async predicate until truthy; named TimeoutError otherwise."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        r = pred()
        r = await r if asyncio.iscoroutine(r) else r
        if r:
            return r
        await asyncio.sleep(poll)
    raise TimeoutError(f"{what} did not happen within {timeout}s")


async def _mkdir(cdp, path: str) -> None:
    await cdp.evaluate(
        f"app.vault.createFolder({json.dumps(path)}).then(() => true)",
        await_promise=True,
    )


async def _rmdir(cdp, path: str) -> None:
    """Delete a folder the way a user does (vault `delete` event fires)."""
    await cdp.evaluate(
        f"""
        (async () => {{
          const f = app.vault.getAbstractFileByPath({json.dumps(path)});
          if (f) await app.vault.delete(f, true);
          return true;
        }})()
        """,
        await_promise=True,
    )


async def _tracked(cdp, path: str) -> bool:
    """The plugin's explicit-folder set holds `path` (a delete is only pushed then)."""
    return await cdp.evaluate(f"{ENGINE_PATH}.explicitFolders.has({json.dumps(path)})") is True


def _safe_delete_folder(api, path: str) -> None:
    """Best-effort server cleanup in `finally`: never mask the test's own failure."""
    try:
        api.delete_folder(path)
    except Exception:  # noqa: BLE001
        pass


# -- 1: server DELETE fails, the folder must not come back -------------------


@pytest.mark.asyncio
async def test_failed_folder_delete_is_retried_not_resurrected(vault_a, cdp_a, api_sync):
    tag = uuid.uuid4().hex[:10]
    folder, nudge = f"E2E/Doomed108-{tag}", f"E2E/Nudge108-{tag}"
    try:
        # Setup: a tracked folder the server also lists (so a delete is pushed).
        await _mkdir(cdp_a, folder)
        await _wait_until(lambda: _tracked(cdp_a, folder), DELIVERY_TIMEOUT, "plugin tracking the folder")
        await _wait_until(
            lambda: folder in api_sync.get_explicit_folders(), DELIVERY_TIMEOUT, "server marker for the folder"
        )

        async with api_fault(cdp_a, "DELETE", r"^/folders/", 500, times=1):
            await _rmdir(cdp_a, folder)
            hits = await _wait_until(
                lambda: _faulted(cdp_a), 30, "the injected DELETE failure to fire"
            )
            assert any(folder.split("/")[-1] in h["path"] for h in hits), (
                f"wrapper fired, but not for our folder: {hits}"
            )
            assert not (vault_a / folder).exists(), "folder should be gone locally after the delete"
            assert folder in api_sync.get_explicit_folders(), (
                "positive control: the failed DELETE must have left the server marker in place"
            )

            # catchUp only re-reads the folder list when the server moved on (the
            # unchanged-manifest short-circuit), so make an unrelated server write.
            assert api_sync.create_folder(nudge) in (200, 201)
            await cdp_a.trigger_catch_up()
            await asyncio.sleep(1)
            assert not (vault_a / folder).exists(), "the pull resurrected the deleted folder"

            all_hits = await read_api_fault(cdp_a)
            await _wait_until(
                lambda: folder not in api_sync.get_explicit_folders(),
                30,
                f"the retry to delete the server marker (hits so far: {all_hits})",
            )
            assert not (vault_a / folder).exists(), "the pull resurrected the deleted folder"
            await asyncio.sleep(2)  # a late resurrection would land here
            assert not (vault_a / folder).exists(), "the folder came back after the retry"
            deletes = [h for h in await read_api_fault(cdp_a) if folder.split("/")[-1] in h["path"]]
            assert [h["faulted"] for h in deletes][:2] == [True, False], (
                f"expected one failed DELETE then one retried DELETE, got {deletes}"
            )
    finally:
        _safe_delete_folder(api_sync, folder)
        _safe_delete_folder(api_sync, nudge)
        await _rmdir(cdp_a, folder)
        await _rmdir(cdp_a, nudge)


async def _faulted(cdp):
    hits = [h for h in await read_api_fault(cdp) if h["faulted"]]
    return hits or None


# -- 2: 429 + Retry-After on POST /folders -----------------------------------

RETRY_AFTER_S = 10
WINDOW_S = 22
FOLDERS_N = 5


@pytest.mark.asyncio
async def test_folder_post_429_is_not_hammered(vault_a, cdp_a, api_sync):
    tag = uuid.uuid4().hex[:10]
    root = f"E2E/RateLimit108-{tag}"
    names = [f"{root}-{i}" for i in range(FOLDERS_N)]

    def ours(hits):
        return [h for h in hits if (h.get("folder") or "").startswith(root)]

    try:
        async with api_fault(cdp_a, "POST", r"^/folders$", 429, retry_after_s=RETRY_AFTER_S):
            for n in names:
                await _mkdir(cdp_a, n)
            # Oracle: every create POST reached the wrapper and was answered 429.
            await _wait_until(
                lambda: _count_ours(cdp_a, root, FOLDERS_N), 30, "one 429'd POST per created folder"
            )
            await asyncio.sleep(2)  # let the creation burst settle
            window_start = await cdp_a.evaluate("Date.now()")

            # Catch-ups are what re-seed untracked folders; hammer them for a window.
            end = time.monotonic() + WINDOW_S
            while time.monotonic() < end:
                await cdp_a.trigger_catch_up()
                await asyncio.sleep(1)

            window = [h for h in ours(await read_api_fault(cdp_a)) if h["t"] > window_start]
            ceiling = math.ceil(WINDOW_S / RETRY_AFTER_S) + 1
            assert len(window) <= ceiling, (
                f"{len(window)} POSTs for {FOLDERS_N} folders in {WINDOW_S}s of catch-ups "
                f"(Retry-After {RETRY_AFTER_S}s allows at most {ceiling}): the plugin is hammering"
            )
            gaps = [b["t"] - a["t"] for a, b in zip(window, window[1:])]
            assert all(g >= (RETRY_AFTER_S - 1) * 1000 for g in gaps), (
                f"POSTs closer than Retry-After ({RETRY_AFTER_S}s): gaps ms {gaps}"
            )

            # Wrapper off (pass-through): the plugin must recover and land them all.
            await release_api_fault(cdp_a)

        async def landed():
            await cdp_a.trigger_catch_up()
            have = set(api_sync.get_explicit_folders())
            return set(names) <= have

        await _wait_until(landed, 60, "all folders to reach the server after the limit lifted", poll=2)
    finally:
        for n in names:
            _safe_delete_folder(api_sync, n)
            await _rmdir(cdp_a, n)


async def _count_ours(cdp, root: str, n: int) -> bool:
    hits = [h for h in await read_api_fault(cdp) if (h.get("folder") or "").startswith(root)]
    return len(hits) >= n and all(h["faulted"] for h in hits)


# -- 3: refused crdt join -> typed preview error -----------------------------

CONNECTION_COPY = "Could not compare with the cloud. Check your connection."


@pytest.mark.asyncio
async def test_preview_names_a_refused_live_join(cdp_a):
    async def crdt_live() -> bool:
        return await cdp_a.evaluate(f"!!({ENGINE_PATH}.crdtLive && {ENGINE_PATH}.crdtLive())") is True

    async def rejected_reason():
        return await cdp_a.evaluate("app.plugins.plugins['engram-vault-sync'].noteStream.crdtJoinFailedReason")

    try:
        async with crdt_join_downgrade(cdp_a) as rewritten:
            await cdp_a.disconnect_stream()
            await cdp_a.reconnect_stream()
            await _wait_until(
                lambda: rejected_reason(), 30, "the backend to refuse the downgraded crdt join"
            )
            assert await rewritten() >= 1, "the join frame was never rewritten: nothing was injected"
            assert await rejected_reason() == "crdt_proto_too_old"
            assert not await crdt_live(), "positive control: the crdt topic must not be live"

            await cdp_a.reset_sync_gate()
            started = time.monotonic()
            await cdp_a.open_sync_preview_modal()
            text = await _wait_until(
                lambda: cdp_a.evaluate(
                    "document.querySelector('.engram-sync-preview-modal .engram-sync-preview-picker-error')"
                    "?.textContent || ''"
                ),
                20,
                "the preview modal to show an error",
            )
            elapsed = time.monotonic() - started
        assert text != CONNECTION_COPY, f"preview blamed the connection for a refused join: {text!r}"
        assert "Live sync was refused" in text, f"preview error is not the typed join reason: {text!r}"
        # The wait budget for a socket that is merely slow is 8s; a refusal is known now.
        assert elapsed < 7, f"preview took {elapsed:.1f}s to fail: it waited instead of failing fast"
    finally:
        try:
            await cdp_a.dismiss_modals()
        finally:
            await cdp_a.disconnect_stream()
            await cdp_a.reconnect_stream()
            await cdp_a.wait_for_stream_connected()
            await _wait_until(crdt_live, 60, "the crdt topic to rejoin after un-injecting")
            await cdp_a.accept_sync_gate()


# -- 4: empty-name folder paths never create a folder ------------------------


@pytest.mark.asyncio
async def test_empty_name_folder_paths_create_nothing(vault_a, cdp_a, api_sync):
    tag = uuid.uuid4().hex[:10]
    root = f"E2E/EmptyName108-{tag}"
    before_server = set(api_sync.get_explicit_folders())
    try:
        calls = [
            f"{ENGINE_PATH}.ensureFolder('')",
            f"{ENGINE_PATH}.ensureFolder({json.dumps(root + '//')})",
            f"{ENGINE_PATH}.ensureFolder({json.dumps(root + '//deep')})",
            f"{ENGINE_PATH}.createFolderNow('')",
            f"{ENGINE_PATH}.createFolderNow({json.dumps(root + '//')})",
            f"{ENGINE_PATH}.handleFolderCreate({{path: ''}})",
            f"{ENGINE_PATH}.handleFolderCreate({{path: {json.dumps(root + '//')}}})",
        ]
        for c in calls:
            await cdp_a.evaluate(f"(async () => {{ try {{ await {c}; }} catch (e) {{}} return true; }})()", await_promise=True)

        await asyncio.sleep(2)  # let any async push land
        local = await cdp_a.evaluate(
            "app.vault.getAllLoadedFiles().filter(f => 'children' in f).map(f => f.path)"
        )
        bad_local = [p for p in local if p != "/" and "" in p.split("/")]
        assert not bad_local, f"empty-name folders in the vault: {bad_local}"
        bad_server = [
            p for p in set(api_sync.get_explicit_folders()) - before_server if "" in p.split("/")
        ]
        assert not bad_server, f"empty-name folders on the server: {bad_server}"
        # Positive control: the guard cleaned the path, it did not just swallow the call.
        assert (vault_a / root).is_dir(), "the cleaned path was never created"
    finally:
        for p in (f"{root}/deep", root):
            _safe_delete_folder(api_sync, p)
            await _rmdir(cdp_a, p)
