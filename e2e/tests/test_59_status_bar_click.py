"""Test 59: Status bar click — gate state determines behavior.

User paths covered:
  1. Gate blocked  → clicking the status bar opens SyncPreviewModal so the
                     user can pick a sync direction.
  2. Gate unblocked → clicking the status bar fires fullSync() and the
                     lastSync timestamp advances.

Seed/restore rationale:
  test_click_blocked_opens_modal:
    - Pauses outgoing sync so the seeded file does not race-push before the
      gate is closed.
    - Resets the gate (syncBlocked=true, syncGateAcceptedFor=null) to force
      the blocked branch.
    - The finally block dismisses any open modals via Escape, unlinks the
      seed file, restores the sync handlers, and re-accepts the gate so
      subsequent tests are not left in a blocked state.

  test_click_unblocked_triggers_sync:
    - Relies on the gate being open (normal post-conftest state).
    - Does not mutate vault files — only measures lastSync advancement.
    - Does not need a restore block because no persistent state is changed.
"""

from __future__ import annotations

import asyncio

import pytest
from helpers.vault import write_note


# ---------------------------------------------------------------------------
# Skip gate — skip both tests when the plugin lacks the SyncPreviewModal API
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _require_gate(cdp_a):
    if not await cdp_a.has_sync_gate():
        pytest.skip("Plugin lacks SyncPreviewModal gate API")


# ---------------------------------------------------------------------------
# test_click_blocked_opens_modal
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_click_blocked_opens_modal(vault_a, cdp_a):
    """Gate blocked: status bar click opens SyncPreviewModal."""
    seed_path = "E2E/StatusBar59/Block.md"

    # Pause outgoing sync before writing the seed file so the engine cannot
    # push it while the gate is closed — avoids a confusing race where the
    # engine tries to flush while syncBlocked=true.
    await cdp_a.pause_outgoing_sync()
    write_note(vault_a, seed_path, "# seed")

    # Close the gate: clears saved fingerprint and sets syncBlocked=true.
    await cdp_a.reset_sync_gate()

    try:
        # The click handler reads isSyncBlocked() and must see true here.
        await cdp_a.click_status_bar()

        # doSyncWithFirstSyncCheck() is async and calls computeSyncPlan()
        # before rendering the modal — give it a generous window.
        await cdp_a.wait_for_sync_preview_modal(timeout=10)

    finally:
        # Dismiss any open modals so later tests start clean.
        await cdp_a.evaluate(
            "document.querySelectorAll('.modal-container .modal').forEach("
            "  m => m.dispatchEvent(new KeyboardEvent('keydown', "
            "    {key: 'Escape', bubbles: true}))"
            ")"
        )
        # Remove the seeded file so it does not appear in other tests' plans.
        (vault_a / seed_path).unlink(missing_ok=True)
        # Restore sync handlers before re-accepting the gate so the engine
        # can push normally again once the gate is open.
        await cdp_a.resume_outgoing_sync()
        # Re-open the gate so subsequent tests are not left in blocked state.
        await cdp_a.accept_sync_gate()


# ---------------------------------------------------------------------------
# test_click_unblocked_triggers_sync
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_click_unblocked_triggers_sync(cdp_a):
    """Gate open: status bar click fires fullSync and lastSync advances."""
    before = await cdp_a.get_last_sync()

    await cdp_a.click_status_bar()

    # fullSync is async; poll up to 10 s for lastSync to change.
    deadline = asyncio.get_event_loop().time() + 10
    after = before
    while asyncio.get_event_loop().time() < deadline:
        after = await cdp_a.get_last_sync()
        if after != before:
            break
        await asyncio.sleep(0.25)

    assert after != before, (
        f"lastSync did not advance after status bar click "
        f"(before={before!r}, after={after!r})"
    )
