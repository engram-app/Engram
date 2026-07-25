"""Test 59: Status bar click — gate state determines behavior.

User paths covered:
  1. Gate blocked  → clicking the status bar opens SyncPreviewModal so the
                     user can pick a sync direction.
  2. Gate unblocked → clicking the status bar runs a sync that pulls a
                     pending server change down into the vault.

Seed/restore rationale:
  test_click_blocked_opens_modal:
    - Pauses outgoing sync so the seeded file does not race-push before the
      gate is closed.
    - Resets the gate (syncBlocked=true, syncGateAcceptedFor=null) to force
      the blocked branch.
    - The finally block dismisses any open modals via Escape, unlinks the
      seed file, restores the sync handlers, and re-accepts the gate so
      subsequent tests are not left in a blocked state.

  test_click_triggers_sync_pull:
    - Relies on the gate being open (normal post-conftest state).
    - Creates a note server-side, clicks the status bar, asserts the pull
      lands it locally. lastSync is frozen post-B2 (opaque syncCursor is the
      watermark), so behavior — not timestamp advancement — is asserted.
    - Does not need a restore block because no local vault state is mutated.
"""

from __future__ import annotations

import uuid

import pytest
from helpers.vault import wait_for_content, write_note


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
# test_click_triggers_sync_pull
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_click_triggers_sync_pull(vault_a, cdp_a, api_sync):
    """Gate open: status bar click runs a sync that pulls a pending change.

    Post-B2, lastSync is frozen (the opaque syncCursor is the watermark), so
    "lastSync advances" is no longer a valid signal. We create a note on the
    server out-of-band, click the status bar, and assert the resulting sync
    lands the note locally — a behavior assertion independent of cursor state.
    """
    unique = uuid.uuid4().hex[:12]
    path = f"E2E/StatusBarClick-{unique}.md"
    marker = f"status-bar pull marker {unique}"
    content = f"# Status Bar Click\n{marker}"

    # Create the note server-side (out-of-band — not via the local vault).
    api_sync.create_note(path, content)

    # The gate is open in normal post-conftest state; a click runs fullSync.
    await cdp_a.click_status_bar()

    # The note must arrive locally as a result of the sync the click ran.
    local = wait_for_content(vault_a, path, marker)
    assert marker in local, (
        f"status bar click did not pull pending server change into {path!r}"
    )
