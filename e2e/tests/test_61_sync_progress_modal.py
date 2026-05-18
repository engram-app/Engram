"""Test 61: SyncProgressModal phases + 'Run in background'.

User path covered:
  During a bulk push operation SyncProgressModal opens, the phase label
  advances through "Pushing notes" (and optionally "Complete"), the progress
  bar increments, and clicking "Run in background" dismisses the modal while
  the sync continues in the engine.

Why 50 files + 50 ms per-file delay:
  pushAll batches files in groups of 10 and only fires onSyncProgress at the
  end of each batch (~10 × 10 ms = ~100 ms per batch for 50 files).  On a
  fast machine the whole push can finish in under 1 s before the test gets a
  chance to sample the phase label.  Patching pushFile with a 50 ms per-file
  artificial delay stretches 50 files to roughly 5 s of modal time, giving
  the polling loop ample window to capture at least one mid-push sample.

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
SEED_COUNT = 50


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
        # Open the progress modal via the plugin's own openProgressModal()
        # which wires onSyncProgress and opens the modal, then fire pushAll
        # as a fire-and-forget task (do NOT await here — we poll while it runs).
        # ------------------------------------------------------------------
        await cdp_a.evaluate(
            f"(async () => {{"
            f"const p = {PLUGIN_PATH};"
            f"window.__e2e_progressModal = await p.settings.openProgressModal();"
            f"window.__e2e_pushAllPromise = p.syncEngine.pushAll();"
            f"}})()",
            await_promise=True,
        )

        # ------------------------------------------------------------------
        # Poll for up to 10 s, sampling the phase label and bar every 250 ms.
        # ------------------------------------------------------------------
        seen_phases: set[str] = set()
        seen_percents: list[int] = []

        for _ in range(40):
            phase = await cdp_a.get_progress_phase()
            if phase and phase.strip():
                seen_phases.add(phase.strip())
            pct = await cdp_a.get_progress_percent()
            if pct is not None:
                seen_percents.append(pct)
            await asyncio.sleep(0.25)

        # At least one sample must contain the push-phase label.
        assert any(
            "Pushing" in p or "pushing" in p.lower() for p in seen_phases
        ), f"Expected a 'Pushing notes' phase label, got {seen_phases!r}"

        # Progress bar must have advanced (at least one non-zero sample).
        assert any(v > 0 for v in seen_percents), (
            f"Progress bar never advanced from 0%. Samples: {seen_percents}"
        )

        # ------------------------------------------------------------------
        # Click "Run in background" if the button is still visible.
        # It auto-hides once sync reaches the "complete" phase.
        # ------------------------------------------------------------------
        bg_visible = await cdp_a.evaluate(
            "Boolean(Array.from(document.querySelectorAll("
            "'.engram-sync-progress-modal .engram-progress-buttons button'))"
            ".find(b => b.textContent.trim() === 'Run in background'))"
        )
        if bg_visible:
            await cdp_a.click_progress_background()
            await cdp_a.wait_for_progress_modal_closed(timeout=5)

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
