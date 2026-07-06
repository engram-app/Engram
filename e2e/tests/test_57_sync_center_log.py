"""Test 57: Sync Center — activity log records push then clears.

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

# NOTE: test_restore_ignored_resyncs_file was removed in PR #148 — the
# push_file_now() call doesn't reliably reach the server within 5s after
# the Ignore-then-Restore round-trip due to an internal race condition.
# The Restore UI path has no deterministic CDP trigger.
"""

from __future__ import annotations

import asyncio
import time

import pytest

from helpers.vault import delete_note


SEED_DIR = "E2E/Activity57"


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
# Test 1: Activity log records push, Clear empties it
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_activity_log_records_push_then_clears(vault_a, cdp_a, api_sync):
    """Push a note → confirm 'push' entry in activity log → Clear → empty."""
    path = f"{SEED_DIR}/Logged.md"
    wrote = False
    try:
        # ── 1. Deterministically push the note via the engine ────────────────
        # Ensure the CRDT channel is live first. push_file_now routes a small
        # note via the CRDT path, which returns "CRDT push ok" WITHOUT verifying
        # the channel is joined — so if an upstream auth-swap test (test_47/48/49)
        # on this shared session-scoped instance left the channel dead-but-set,
        # the Y.Doc update is silently dropped and the note never reaches the
        # server (#915). Force a live channel so the push actually lands.
        if not await cdp_a.check_stream_connected():
            await cdp_a.reconnect_stream()
        await cdp_a.wait_for_stream_connected()

        # push_file_now() creates via app.vault.create() and awaits pushFile()
        # directly, bypassing the handleModify debounce. It also appends a
        # 'push' entry to syncLog so the activity log assertion has a target.
        await cdp_a.push_file_now(path, "# activity log test")
        wrote = True

        # Confirm the push reached the server. Load-tolerant budget: under runner
        # contention CRDT propagation can lag past a tight window (#915).
        api_sync.wait_for_note(path, timeout=15)

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

