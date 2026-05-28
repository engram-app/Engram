"""Shared conflict test setup — used by test_06, test_13, test_14, test_21, test_22,
test_54.

Extracts two patterns:

1. ``setup_conflict`` — the original 5-step pattern used by test_06/13/14/21/22:
   A creates base note, B syncs to get it, A edits, B pauses and edits locally.
   Requires api_sync fixture.

2. ``setup_conflict_for_a`` / ``restore_after_conflict`` — the simpler 2-party
   pattern for test_54 (ConflictModal UI):
   B writes remote content and syncs to server, then A writes local content and
   triggers pull so that Vault A detects divergence and opens ConflictModal
   (requires ``conflictResolution == 'modal'`` already set on A before call).
   Does NOT require api_sync.
"""

from __future__ import annotations

import asyncio
import json
import time

from helpers.vault import write_note


# How long to wait for ConflictModal to mount after pull() dispatches
# resolveConflict. The modal genuinely opens just outside 10 s on a loaded CI
# runner (the seed does 8+ CDP round-trips first), so a 10 s budget produced
# rerun-pass flakes (issue #192). 20 s keeps real-time intent while absorbing
# CI load; the modal-open path itself is unchanged.
_MODAL_OPEN_TIMEOUT_S = 20


# Snapshot helper for setup_conflict_for_a step-by-step diagnostics.
# Captures everything we need to figure out which step lost syncState.
_SNAPSHOT_JS = """
((path) => {
    const p = app.plugins.plugins['engram-vault-sync'];
    const se = p.syncEngine;
    const ss = se.syncState.get(path);
    const bs = p.baseStore?.get?.(path);
    const file = app.vault.getFileByPath(path);
    let content = null;
    let contentLen = null;
    if (file) {
        try {
            // sync read of cached content if available
            const cached = app.vault.cachedRead
                ? null /* async, skip in sync snapshot */
                : null;
            contentLen = file.stat?.size ?? null;
        } catch (_) {}
    }
    const allFiles = app.vault.getFiles();
    const inGetFiles = allFiles.some(f => f.path === path);
    return JSON.stringify({
        conflictResolution: p.settings.conflictResolution,
        vaultId: p.settings.vaultId,
        lastSync: se.lastSync,
        syncBlocked: se.syncBlocked,
        pulling: !!se.pulling,
        pushingHas: se.pushing?.has?.(path) ?? null,
        pushingSize: se.pushing?.size ?? null,
        recentlyPushed: se.isRecentlyPushed?.(path) ?? null,
        syncStatePresent: !!ss,
        syncStateHash: ss?.hash ?? null,
        syncStateVersion: ss?.version ?? null,
        baseStorePresent: !!bs,
        baseLen: bs ? (bs.content || '').length : null,
        baseVersion: bs?.version ?? null,
        fileInIndex: !!file,
        fileInGetFiles: inGetFiles,
        fileMtime: file?.stat?.mtime ?? null,
        fileSize: file?.stat?.size ?? null,
        getFilesCount: allFiles.length,
        incomingPaused: !!se._origHandleStreamEvent,
        outgoingPaused: !!se._origHandleModify,
        ready: se.ready,
        debounceTimersCount: se.debounceTimers?.size ?? null,
    });
})
"""


async def _snapshot(cdp, path: str) -> dict:
    """Capture engine state for diagnostics at a setup_conflict_for_a step."""
    js = f"({_SNAPSHOT_JS})({json.dumps(path)})"
    raw = await cdp.evaluate(js)
    try:
        return json.loads(raw) if isinstance(raw, str) else {}
    except Exception:
        return {"_raw": raw}


async def setup_conflict(
    path: str,
    vault_a,
    vault_b,
    cdp_b,
    api_sync,
    *,
    a_edit: str = "Edited by A",
    b_edit: str = "Edited by B",
    base_content: str = "Base content",
):
    """Create a conflict: A and B both edit the same note.

    After this function returns:
    - Server has A's version
    - B has B's version locally (outgoing sync paused)
    - B's syncedHash records the original base, so pull will detect conflict

    Raises AssertionError if pause_outgoing_sync failed to prevent B's push.
    """
    # 1. A creates the base note
    write_note(vault_a, path, f"# Conflict Test\n{base_content}")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls to establish synced state (records syncedHash)
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note after pull"

    # 3. A edits → push to server
    write_note(vault_a, path, f"# Conflict Test\n{a_edit}")
    api_sync.wait_for_note_content(path, a_edit, timeout=10)

    # 4. Pause B's outgoing sync so B's edit stays local-only
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally
    write_note(vault_b, path, f"# Conflict Test\n{b_edit}")

    # 6. Verify pause is working — B's edit must NOT overwrite A's on server.
    #    Plugin debounce is 300ms; 1s = 3x margin for push to have fired if unpaused.
    time.sleep(1)
    server_note = api_sync.get_note(path)
    assert server_note is not None, "Server note disappeared during conflict setup"
    assert b_edit not in server_note.get("content", ""), (
        f"pause_outgoing_sync FAILED: B's edit '{b_edit}' reached the server. "
        f"All conflict tests using this helper are invalid."
    )


# ---------------------------------------------------------------------------
# Two-party conflict helpers for test_54 (ConflictModal UI)
# ---------------------------------------------------------------------------


async def setup_conflict_for_a(
    vault_a,
    vault_b,
    cdp_a,
    cdp_b,
    path: str,
    *,
    local: str,
    remote: str,
    base: str | None = None,
) -> None:
    """Seed a 3-way conflict that opens ConflictModal on Vault A.

    The plugin only treats a divergent pull as a *real* conflict when both:

      - it has a recorded ``syncedHash`` for the file (so the local edit is
        provably user-modified, not first-sync staleness), AND
      - ``localContent != remoteContent``.

    Without a recorded sync state the engine falls into its first-sync staleness
    heuristic (``STALE_THRESHOLD_S = 3600`` s; see src/sync.ts ~1330) and may
    silently accept the remote, never opening ConflictModal.

    So we establish a synced *base* first:

    1. A writes ``base`` content and triggers a full sync — server now has the
       base AND ``syncState`` on A records its hash.
    2. B also fully syncs so B has the same base recorded locally.
    3. Pause A's outgoing sync so A's divergent edit stays off-server.
    4. A writes ``local`` (diverges from base).
    5. B writes ``remote`` (diverges from base) and full-syncs — server now
       carries B's divergent version.
    6. Resume A's outgoing sync, then trigger a pull — A sees server content
       that differs from its local content AND its recorded base hash; with
       ``conflictResolution == 'modal'`` set, ConflictModal opens.

    If ``base`` is None, a deterministic placeholder is derived from ``path``.

    The caller MUST set ``conflictResolution = 'modal'`` on A before calling
    (the ``_set_modal_mode`` autouse fixture in test_54 does this).

    Waits up to 10 s for the modal DOM node to appear; raises TimeoutError if
    it never mounts.
    """
    if base is None:
        base = f"# base\nseed for {path}\n"

    # 0. Defensive: dismiss any leftover conflict modal from a prior aborted
    #    run.  pytest-rerunfailures retries the same test in the same browser
    #    process, so a previous attempt's open modal would block the new pull
    #    (resolveConflict is single-flight per file but a stale modal hides
    #    test failures behind a 180 s timeout).
    await cdp_a.evaluate(
        "(() => { "
        "const m = document.querySelector("
        "'.engram-conflict-modal .engram-conflict-actions'); "
        "if (!m) return; "
        "const skip = Array.from(m.querySelectorAll('button'))"
        ".find(b => b.textContent.trim() === 'Skip'); "
        "skip?.click(); "
        "})()"
    )

    # Diagnostic snapshots per step — accumulate so on a modal-mount
    # timeout we can pinpoint which step lost syncState/baseStore.
    snapshots: list[tuple[str, dict]] = []
    snapshots.append(("step0_after_dismiss", await _snapshot(cdp_a, path)))

    # 1. A writes the base content and syncs — establishes syncedHash on A
    #    and base content on the server. Use vault_write (Obsidian's vault
    #    API) instead of write_note so the file is in getFiles() before
    #    fullSync iterates — raw filesystem writes are picked up only when
    #    the watcher eventually fires, which races against trigger_full_sync.
    await cdp_a.vault_write(path, base)
    snapshots.append(("step1a_after_vault_write_base", await _snapshot(cdp_a, path)))
    step1_full_sync_result = await cdp_a.trigger_full_sync()
    snapshots.append(("step1b_after_trigger_full_sync", await _snapshot(cdp_a, path)))
    snapshots.append(
        ("step1b_full_sync_result", {"result": step1_full_sync_result})
    )

    # 2. B pulls so it also records the same base in its syncState. Not strictly
    #    required for ConflictModal on A, but keeps both sides consistent for
    #    test_54's eventual restore.
    await cdp_b.trigger_full_sync()
    snapshots.append(("step2_after_b_full_sync", await _snapshot(cdp_a, path)))

    # 3. Pause A's outgoing sync so the local divergent write stays off-server.
    await cdp_a.pause_outgoing_sync()

    # 3b. Pause A's incoming WebSocket events so the broadcast from step 5
    #     (B's push) cannot race pull() under resolveConflict's single-flight
    #     gate. Without this, the WS path and the pull path both try to open
    #     ConflictModal for the same `path`; under specific edit-range
    #     geometries the interleaving silently auto-resolves and neither
    #     mounts the modal — the test_54 PerHunk flake on PR #162.
    await cdp_a.pause_incoming_sync()
    snapshots.append(("step3_after_pauses", await _snapshot(cdp_a, path)))

    # 4. A writes local divergence (now: localHash != lastSyncedHash → modified).
    #    vault_write ensures pull() in step 6 reads the local content from the
    #    same path Obsidian's index knows about. handleModify is a no-op while
    #    paused, so no push leaks out.
    await cdp_a.vault_write(path, local)
    snapshots.append(("step4_after_vault_write_local", await _snapshot(cdp_a, path)))

    # 5. B writes remote divergence and syncs so the server carries B's version.
    await cdp_b.vault_write(path, remote)
    await cdp_b.trigger_full_sync()
    snapshots.append(("step5_after_b_writes_remote", await _snapshot(cdp_a, path)))

    # 6. Resume A's outgoing sync, then pull — divergence is detected and
    #    ConflictModal opens.
    #
    # CRITICAL: do NOT await pull()'s promise here.  In 'modal' mode pull()
    # invokes resolveConflict() which awaits onConflict() — i.e. user
    # interaction with the modal we're trying to surface.  Awaiting the pull
    # would deadlock the seed: the seed waits for pull to resolve, pull waits
    # for the modal click, no test code has run yet to click.
    #
    # Fire-and-forget: dispatch pull() and rely on the modal-mount poll below
    # to know when the seed has reached the user-interaction point. Incoming
    # WS handling stays paused — pull is the only conflict-detection path.
    await cdp_a.resume_outgoing_sync()
    snapshots.append(("step6a_after_resume_outgoing", await _snapshot(cdp_a, path)))
    # Instrument resolveConflict so we can see whether pull reached it at all
    # (and what info.path was). Stored on the engine for the timeout dump.
    await cdp_a.evaluate(
        """
        (() => {
            const se = app.plugins.plugins['engram-vault-sync'].syncEngine;
            if (se._origResolveConflict) return 'already-wrapped';
            se._resolveConflictCalls = [];
            se._origResolveConflict = se.resolveConflict.bind(se);
            se.resolveConflict = (info) => {
                try {
                    se._resolveConflictCalls.push({
                        path: info.path,
                        localLen: info.localContent?.length ?? null,
                        remoteLen: info.remoteContent?.length ?? null,
                        baseLen: info.baseContent?.length ?? null,
                        ts: Date.now(),
                    });
                } catch (_) {}
                return se._origResolveConflict(info);
            };
            return 'wrapped';
        })()
        """
    )
    # No await_promise — dispatch pull() and return immediately so the seed
    # can poll for the modal that pull() is about to surface.
    await cdp_a.evaluate(
        "void app.plugins.plugins['engram-vault-sync']"
        ".syncEngine.pull(); 'dispatched'"
    )
    snapshots.append(("step6b_after_pull_dispatched", await _snapshot(cdp_a, path)))

    # Wait for ConflictModal to mount (pull dispatches resolveConflict which
    # opens the modal asynchronously).
    deadline = time.monotonic() + _MODAL_OPEN_TIMEOUT_S
    while time.monotonic() < deadline:
        present = await cdp_a.evaluate(
            "Boolean(document.querySelector('.engram-conflict-modal'))"
        )
        if present:
            # Modal up. Restore WS handler so the rest of the test (and
            # restore_after_conflict) observes normal events again. Also
            # unwrap the resolveConflict diagnostic wrapper so subsequent
            # test invocations don't stack additional wrappers each time.
            await cdp_a.resume_incoming_sync()
            try:
                await cdp_a.evaluate(
                    """
                    (() => {
                        const se = app.plugins.plugins['engram-vault-sync'].syncEngine;
                        if (se._origResolveConflict) {
                            se.resolveConflict = se._origResolveConflict;
                            delete se._origResolveConflict;
                        }
                    })()
                    """
                )
            except Exception:
                pass
            return
        await asyncio.sleep(0.2)

    # Modal never mounted. Capture full diagnostic dump: per-step snapshots
    # taken during the seed, the final engine state, and any resolveConflict
    # invocations the instrumented pull recorded. Lets the next CI failure
    # pinpoint exactly which step lost state vs. which step ran clean.
    final_state = await _snapshot(cdp_a, path)
    resolve_calls = await cdp_a.evaluate(
        "JSON.stringify(app.plugins.plugins['engram-vault-sync']"
        ".syncEngine._resolveConflictCalls || [])"
    )
    try:
        resolve_calls_parsed = json.loads(resolve_calls) if isinstance(resolve_calls, str) else []
    except Exception:
        resolve_calls_parsed = []
    # Best-effort restore so we don't poison downstream cleanup paths.
    try:
        await cdp_a.resume_incoming_sync()
    except Exception:
        pass
    # Best-effort unwrap so subsequent test attempts don't accumulate wrappers.
    try:
        await cdp_a.evaluate(
            """
            (() => {
                const se = app.plugins.plugins['engram-vault-sync'].syncEngine;
                if (se._origResolveConflict) {
                    se.resolveConflict = se._origResolveConflict;
                    delete se._origResolveConflict;
                }
            })()
            """
        )
    except Exception:
        pass
    snapshots.append(("final_at_timeout", final_state))
    snapshot_dump = "\n".join(
        f"  {name}: {json.dumps(snap, sort_keys=True)}" for name, snap in snapshots
    )
    raise TimeoutError(
        f"ConflictModal never opened for path '{path}' within {_MODAL_OPEN_TIMEOUT_S} s\n"
        f"resolveConflict invocations during pull: "
        f"{json.dumps(resolve_calls_parsed)}\n"
        f"per-step snapshots:\n{snapshot_dump}"
    )


async def restore_after_conflict(
    vault_a,
    vault_b,
    cdp_a,
    cdp_b,
    path: str,
) -> None:
    """Remove the seeded file from both vaults and reconcile with the server.

    Deletes the file from both local vaults then triggers a full sync on each
    so the server also removes its copy.  Safe to call even if the file is
    already absent (``missing_ok=True``).
    """
    (vault_a / path).unlink(missing_ok=True)
    (vault_b / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
    await cdp_b.trigger_full_sync()
