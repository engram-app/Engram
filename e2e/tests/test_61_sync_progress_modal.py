"""Test 61: SyncProgressModal phases + 'Run in background'.

User path covered:
  During a bulk push operation SyncProgressModal opens, the phase label
  advances through "Pushing notes" (and optionally "Complete"), the progress
  bar increments, and clicking "Run in background" dismisses the modal while
  the sync continues in the engine.

Why 5 files + 50 ms per-file delay:
  pushAll batches files in groups of 10 and only fires onSyncProgress at the
  end of each batch.  We don't need to observe a long-running push window —
  we need to *observe at least one mid-push event* and confirm the "bg"
  button is wired.  An onSyncProgress recorder captures every emission, so
  5 files × 50 ms = ~250 ms of in-flight push time is plenty.  Smaller seed
  also means O(N) cleanup runs ~10× faster.

Selector corrections vs plan draft (sync-progress-modal.ts):
  - Phase:   .engram-progress-phase  (plan used .engram-phase — missing)
  - Bar:     div.engram-progress-bar-inner style.width  (plan used <progress>
             value — no <progress> element in source)
  - BG btn:  text "Run in background" inside .engram-progress-buttons
             (plan used .engram-bg-btn class — not present in source)

Modal wiring:
  SyncProgressModal is NOT opened automatically when the 'push-all' command
  runs — the command calls syncEngine.pushAll() with no progress modal.  The
  modal is only wired via plugin.settings.openProgressModal() (called from
  the settings UI push/pull buttons).  In this test we replicate that wiring
  before firing pushAll: call plugin.settings.openProgressModal() which
  installs onSyncProgress on the engine and opens the modal, then fire
  pushAll as a fire-and-forget task.

Restore strategy (finally block):
  1. Remove the pushFile delay patch (restore window.__e2e_origPushFile).
  2. Clear the onSyncProgress callback (set to null).
  3. Settle the background pushAll promise so the engine is idle.
  4. Delete all 50 seeded files from disk.
  5. Call trigger_full_sync() so the server learns the files are gone.
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.cdp import ENGINE_PATH, PLUGIN_PATH
from helpers.vault import delete_note, write_note


SEED_DIR = "E2E/Progress61"
# 5 files × 50 ms pushFile patch ≈ 250 ms of push time — enough for the
# onSyncProgress recorder to capture multiple mid-push events without
# stretching the test to 5+ seconds.
SEED_COUNT = 5


# ---------------------------------------------------------------------------
# Skip gate
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _require_progress_modal(cdp_a):
    """Skip when the loaded plugin build predates SyncProgressModal.

    We detect presence by checking that onSyncProgress is a property on the
    sync engine (it was introduced together with SyncProgressModal).
    """
    has_field = await cdp_a.evaluate(
        f"'onSyncProgress' in {ENGINE_PATH}"
    )
    if not has_field:
        pytest.skip("Plugin lacks onSyncProgress — SyncProgressModal not present")


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_phases_advance_and_bg_button_closes(vault_a, cdp_a):
    """SyncProgressModal shows push phase labels; bg button closes the modal."""
    # ------------------------------------------------------------------
    # Seed 50 small files so the push takes long enough to observe phases.
    # ------------------------------------------------------------------
    for i in range(SEED_COUNT):
        write_note(
            vault_a,
            f"{SEED_DIR}/n{i:03d}.md",
            f"# Note {i}\n\nSeed content for progress modal test.\n",
        )

    # ------------------------------------------------------------------
    # Install a 50 ms per-file delay on pushFile to slow the push to ~5 s.
    # pushFile is the private per-file helper called in the pushAll loop.
    # ------------------------------------------------------------------
    await cdp_a.evaluate(
        f"(() => {{"
        f"const se = {ENGINE_PATH};"
        f"const orig = se.pushFile.bind(se);"
        f"window.__e2e_origPushFile = orig;"
        f"se.pushFile = async (...a) => {{"
        f"await new Promise(r => setTimeout(r, 50));"
        f"return orig(...a);"
        f"}};"
        f"}})()"
    )

    try:
        # ------------------------------------------------------------------
        # Open the progress modal AND install a recorder that captures every
        # onSyncProgress emission. The recorder wraps whatever callback the
        # modal installed so the modal still updates, but we get an
        # event-by-event record we can inspect — no polling-window race
        # possible.
        # ------------------------------------------------------------------
        await cdp_a.evaluate(
            f"""
            (async () => {{
                const p = {PLUGIN_PATH};
                window.__e2e_progressModal = await p.settings.openProgressModal();
                window.__e2e_progressEvents = [];
                const se = p.syncEngine;
                const modalCb = se.onSyncProgress;
                se.onSyncProgress = (progress) => {{
                    window.__e2e_progressEvents.push({{
                        phase: progress.phase,
                        current: progress.current,
                        total: progress.total,
                        failed: progress.failed,
                    }});
                    if (typeof modalCb === 'function') modalCb(progress);
                }};
                // Fire-and-forget — we want the modal still in 'pushing'
                // state so we can exercise the bg button below.
                window.__e2e_pushAllPromise = se.pushAll();
            }})()
            """,
            await_promise=True,
        )

        # ------------------------------------------------------------------
        # Wait until at least one 'pushing' event with current>0 is recorded
        # — that proves the modal is wired AND the engine is mid-push (bg
        # button is therefore still visible).
        # ------------------------------------------------------------------
        import json as _json
        saw_active_push = False
        for _ in range(40):  # up to 4 s — 5 files × 50 ms = 250 ms in-flight
            events_json = await cdp_a.evaluate(
                "JSON.stringify(window.__e2e_progressEvents || [])"
            )
            events = _json.loads(events_json) if isinstance(events_json, str) else []
            for e in events:
                if e.get("phase") == "pushing" and (e.get("current") or 0) > 0:
                    saw_active_push = True
                    break
            if saw_active_push:
                break
            await asyncio.sleep(0.1)

        assert saw_active_push, (
            "No 'pushing' event with current>0 within 4 s. "
            "pushAll fired no intermediate progress — onSyncProgress "
            "wiring is broken or the 50 ms per-file pushFile patch failed."
        )

        # ------------------------------------------------------------------
        # While still pushing, click "Run in background" — modal must close.
        # ------------------------------------------------------------------
        bg_visible = await cdp_a.evaluate(
            "Boolean(Array.from(document.querySelectorAll("
            "'.engram-sync-progress-modal .engram-progress-buttons button'))"
            ".find(b => b.textContent.trim() === 'Run in background' && !b.hidden))"
        )
        assert bg_visible, (
            "'Run in background' button not visible during 'pushing' phase — "
            "either the modal closed too early or bgBtn.hidden was set "
            "prematurely."
        )
        await cdp_a.click_progress_background()
        await cdp_a.wait_for_progress_modal_closed(timeout=10)

        # ------------------------------------------------------------------
        # Now wait for pushAll to finish so the test exits with the engine
        # idle (cleanup needs a quiescent engine to delete the seed files).
        # ------------------------------------------------------------------
        await cdp_a.evaluate(
            """
            (async () => {
                try { await (window.__e2e_pushAllPromise || Promise.resolve()); }
                catch (_) {}
                return 'done';
            })()
            """,
            await_promise=True,
        )

        # ------------------------------------------------------------------
        # Final assertions on the full event tape.
        # ------------------------------------------------------------------
        events_json = await cdp_a.evaluate(
            "JSON.stringify(window.__e2e_progressEvents || [])"
        )
        events = _json.loads(events_json) if isinstance(events_json, str) else []
        phases = [e.get("phase") for e in events]
        assert "pushing" in phases, (
            f"No 'pushing' phase observed in onSyncProgress events: {phases!r}"
        )
        assert "complete" in phases, (
            f"No 'complete' phase observed in onSyncProgress events: {phases!r}"
        )
        final = events[-1]
        assert final.get("phase") == "complete", (
            f"Final progress event is not 'complete': {final!r}"
        )
        assert final.get("total") == SEED_COUNT, (
            f"Final progress event total mismatch: {final!r} "
            f"(expected total=={SEED_COUNT})"
        )

    finally:
        # ------------------------------------------------------------------
        # Restore pushFile patch.
        # ------------------------------------------------------------------
        await cdp_a.evaluate(
            f"(() => {{"
            f"const se = {ENGINE_PATH};"
            f"if (window.__e2e_origPushFile) {{"
            f"se.pushFile = window.__e2e_origPushFile;"
            f"delete window.__e2e_origPushFile;"
            f"}}"
            f"}})()"
        )

        # Clear onSyncProgress callback installed by openProgressModal.
        await cdp_a.evaluate(f"{ENGINE_PATH}.onSyncProgress = null")

        # Settle the background pushAll promise so the engine is fully idle.
        await cdp_a.evaluate(
            "(async () => {"
            "try { await (window.__e2e_pushAllPromise || Promise.resolve()); }"
            "catch(e) {}"
            "delete window.__e2e_pushAllPromise;"
            "delete window.__e2e_progressModal;"
            "})()",
            await_promise=True,
        )

        # Delete all seeded files from disk.
        for i in range(SEED_COUNT):
            delete_note(vault_a, f"{SEED_DIR}/n{i:03d}.md")

        # Full sync so the server reconciles the deletions.
        await cdp_a.trigger_full_sync()
