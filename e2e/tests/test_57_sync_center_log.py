"""Test 57: Sync Center — activity log + Ignored panel Restore round-trip.

Test 1 — Activity log records push then clears:
  1. Write a note to vault_a.
  2. trigger_full_sync() — pushes note, SyncEngine appends a log entry.
  3. Open Sync Center; get_activity_entries() should contain a 'push' entry
     for the note path.  action value is the raw SyncLogEntry.action string
     ("push", lowercase) as rendered by sync-center-render.ts renderActivityRow.
  4. click_clear_activity() — calls plugin.syncLog.clear() then refresh(),
     emptying the in-memory ring buffer.
  5. get_activity_entries() should return [].
  Cleanup: delete local file, trigger_full_sync.

Test 2 — Restore ignored file re-ingests it to server:
  The Ignore button only exists on Issues panel rows (renderIssueRow in
  sync-center-render.ts), not on arbitrary clean files.  click_issue_action
  cannot find an Ignore button for a healthy note, so we take the documented
  CDP manual-mutation pivot: mutate plugin.syncEngine.ignoredFiles directly
  via CDP, persist, and call syncCenter?.refresh?().

  Flow:
  1. Write a note → trigger_full_sync() so it lands on server.
  2. Manual CDP pivot: add path to ignoredFiles, persist, refresh Sync Center.
  3. Delete note from server via api_sync.delete_note.
  4. Confirm api_sync.get_note returns None.
  5. Open Sync Center; click_restore_ignored → removes from ignoredFiles,
     persists, shows Notice.
  6. trigger_full_sync() — engine now pushes the note (no longer ignored).
  7. api_sync.get_note confirms note is back on server.
  Cleanup: delete from server + local file, ensure ignoredFiles clear.
"""

from __future__ import annotations

import asyncio
import json
import time

import pytest

from helpers.vault import delete_note


SEED_DIR = "E2E/Activity57"


@pytest.fixture(autouse=True)
async def _require_sync_center(cdp_a):
    """Skip the whole module when the loaded plugin predates Sync Center."""
    if not await cdp_a.has_sync_center():
        pytest.skip("Plugin lacks open-sync-center command — skipping")


# ---------------------------------------------------------------------------
# Helper: poll activity entries until a matching entry appears
# ---------------------------------------------------------------------------

async def _wait_for_activity(cdp, predicate, timeout: float = 20) -> list[dict]:
    """Poll get_activity_entries() until predicate returns True for any entry.

    Returns the full entry list once a match is found.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        entries = await cdp.get_activity_entries()
        if any(predicate(e) for e in entries):
            return entries
        await asyncio.sleep(0.5)
    raise TimeoutError(
        f"No matching activity entry appeared within {timeout}s"
    )


# ---------------------------------------------------------------------------
# Helper: CDP manual-mutation pivot — add path to ignoredFiles
# ---------------------------------------------------------------------------

async def _cdp_ignore_file(cdp, path: str) -> None:
    """Directly mutate engine.ignoredFiles via CDP and persist.

    Used because the Sync Center 'Ignore' button only exists on Issues panel
    rows, not arbitrary clean files (renderIssueRow vs renderIgnoredRow in
    sync-center-render.ts).
    """
    escaped = json.dumps(path)
    await cdp.evaluate(
        f"""
        (async () => {{
            const p = app.plugins.plugins['engram-vault-sync'];
            p.syncEngine.ignoredFiles.add({escaped});
            await p.persistEngineState();
            p.syncCenter?.refresh?.();
            return 'ignored';
        }})()
        """,
        await_promise=True,
    )


# ---------------------------------------------------------------------------
# Test 1: Activity log records push, Clear empties it
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_activity_log_records_push_then_clears(vault_a, cdp_a, api_sync):
    """Push a note → confirm 'push' entry in activity log → Clear → empty."""
    path = f"{SEED_DIR}/Logged.md"
    wrote = False
    try:
        # ── 1. Deterministically push the note via the engine ────────────────
        # push_file_now() creates via app.vault.create() and awaits pushFile()
        # directly, bypassing the handleModify debounce. It also appends a
        # 'push' entry to syncLog so the activity log assertion has a target.
        await cdp_a.push_file_now(path, "# activity log test")
        wrote = True

        # Confirm the push reached the server (the helper awaits pushFile, so
        # this should be immediate — the wait_for_note is belt-and-braces).
        api_sync.wait_for_note(path, timeout=5)

        # ── 3. Open Sync Center and assert push entry present ────────────────
        await cdp_a.open_sync_center()

        # Poll — the activity list may not render until after the sync settles.
        entries = await _wait_for_activity(
            cdp_a,
            lambda e: e.get("path", "").endswith("Logged.md") and e.get("action") == "push",
        )

        matching = [
            e for e in entries
            if e.get("path", "").endswith("Logged.md") and e.get("action") == "push"
        ]
        assert matching, (
            f"Expected a 'push' activity entry for Logged.md; got: {entries!r}"
        )
        assert matching[0].get("status") == "ok", (
            f"Expected status 'ok' on push entry; got: {matching[0]!r}"
        )

        # ── 4. Click Clear ───────────────────────────────────────────────────
        await cdp_a.click_clear_activity()

        # Give the UI one render cycle to re-render the empty state.
        await asyncio.sleep(0.4)

        # ── 5. Activity list is now empty ────────────────────────────────────
        after = await cdp_a.get_activity_entries()
        assert after == [], (
            f"Expected empty activity log after Clear; got: {after!r}"
        )

    finally:
        # ── Cleanup ──────────────────────────────────────────────────────────
        if wrote:
            delete_note(vault_a, path)
        try:
            await cdp_a.trigger_full_sync()
        except Exception:
            pass


# ---------------------------------------------------------------------------
# Test 2: Restore ignored file → re-pushed to server
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_restore_ignored_resyncs_file(vault_a, cdp_a, api_sync):
    """CDP-pivot ignore → server delete → Restore → confirm re-pushed to server.

    Resolution of open question in Task 7:
      The Ignore button only exists on Issue panel rows.  Clean files have no
      Ignore button in the Sync Center UI.  This test uses the CDP
      manual-mutation pivot (_cdp_ignore_file) to add the file to
      ignoredFiles, then drives the Restore flow through the real UI.
    """
    path = f"{SEED_DIR}/Restored.md"
    wrote = False
    ignored = False
    try:
        # ── 1. Deterministically push the note via the engine ───────────────
        await cdp_a.push_file_now(path, "# restore test")
        wrote = True
        # Belt-and-braces confirmation that the note reached the server.
        api_sync.wait_for_note(path, timeout=5)

        # ── 2. CDP pivot: add to ignoredFiles, persist, refresh Sync Center ──
        await _cdp_ignore_file(cdp_a, path)
        ignored = True
        await asyncio.sleep(0.3)  # let refresh() re-render

        # ── 3. Delete from server (simulates out-of-sync ignored state) ──────
        api_sync.delete_note(path)
        api_sync.wait_for_note_gone(path, timeout=5)

        # ── 4. Confirm note is absent from server ────────────────────────────
        assert api_sync.get_note(path) is None, (
            "Note should be absent from server after delete"
        )

        # ── 5. Open Sync Center and click Restore ────────────────────────────
        await cdp_a.open_sync_center()

        # Poll until the ignored row appears in the Ignored panel.
        deadline = time.monotonic() + 10
        ignored_list: list[str] = []
        while time.monotonic() < deadline:
            ignored_list = await cdp_a.get_ignored_files()
            if path in ignored_list:
                break
            await asyncio.sleep(0.4)
        assert path in ignored_list, (
            f"Expected {path!r} in Ignored panel; got: {ignored_list!r}"
        )

        await cdp_a.click_restore_ignored(path)
        ignored = False  # restore removes from ignoredFiles

        # Give the UI a moment to persist and refresh.
        await asyncio.sleep(0.4)

        # ── 6. Full sync — engine should now push the note ───────────────────
        # Accept the gate again (Restore may not re-accept it on its own).
        await cdp_a.accept_sync_gate()
        await cdp_a.trigger_full_sync()

        # ── 7. Confirm note is back on server ────────────────────────────────
        note = api_sync.wait_for_note(path, timeout=5)
        assert note is not None, (
            f"Note {path!r} should be on server after Restore + fullSync"
        )

    finally:
        # ── Cleanup ──────────────────────────────────────────────────────────
        # Remove from ignoredFiles if Restore was never clicked (test failed early).
        if ignored:
            try:
                await _cdp_ignore_file(cdp_a, path)  # ensure add idempotent
                # Actually remove it
                await cdp_a.evaluate(
                    f"""
                    (async () => {{
                        const p = app.plugins.plugins['engram-vault-sync'];
                        p.syncEngine.ignoredFiles.remove({json.dumps(path)});
                        await p.persistEngineState();
                        return 'removed';
                    }})()
                    """,
                    await_promise=True,
                )
            except Exception:
                pass

        # Delete from server (may already be gone).
        try:
            api_sync.delete_note(path)
        except Exception:
            pass

        # Delete local file.
        if wrote:
            delete_note(vault_a, path)

        # Re-sync so engine state is clean.
        try:
            await cdp_a.trigger_full_sync()
        except Exception:
            pass
