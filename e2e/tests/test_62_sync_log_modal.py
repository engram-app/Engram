"""Test 62: SyncLogModal renders a push entry after a file is synced.

User path covered:
  1. Write a note to vault A so the plugin pushes it to the server.
  2. Execute the 'show-sync-log' command — opens SyncLogModal.
  3. Assert that the modal is present (.engram-sync-log-modal) and contains
     at least one entry (.engram-sync-log-entry) whose text includes both
     "push" and the expected file path.

Selector corrections vs plan draft (sync-log-modal.ts):
  - Plan used .engram-log-row  — source uses .engram-sync-log-entry.
  - Plan used r.dataset.action / r.dataset.path — there are no data
    attributes in the source.  Each row is a div containing a <span>
    whose text is formatted as:
        "{time}  {icon} {action.padEnd(8)} {path}  {status}"
    We scrape the span's textContent and match "push" + path substring.

Modal wiring:
  'show-sync-log' is a registered command in main.ts (line 264–268).
  We run it via cdp.run_command() which calls
  app.commands.executeCommandById(...).

Cleanup:
  Close any open modals via Escape before restoring state.
  Delete the seeded file and trigger a full sync to clean up the server.
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.cdp import PLUGIN_PATH
from helpers.vault import delete_note


SEED_PATH = "E2E/SyncLog62/push-entry-test.md"


# ---------------------------------------------------------------------------
# Skip gate
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
async def _require_show_sync_log(cdp_a):
    """Skip when the plugin build does not expose the 'show-sync-log' command."""
    has_cmd = await cdp_a.has_command("show-sync-log")
    if not has_cmd:
        pytest.skip("Plugin lacks show-sync-log command — SyncLogModal not present")


# ---------------------------------------------------------------------------
# Test
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_sync_log_modal_shows_push_entry(vault_a, cdp_a):
    """SyncLogModal must contain an entry with action=push for the seeded file."""
    # ------------------------------------------------------------------
    # Deterministically push the note via the engine. push_file_now() awaits
    # pushFile() directly (no debounce race) and appends a 'push' SyncLog
    # entry so the assertion below has a target. Accepts the sync gate as
    # part of the helper.
    # ------------------------------------------------------------------
    await cdp_a.push_file_now(
        SEED_PATH,
        "# Sync log test\n\nThis file should appear in the sync log.\n",
    )

    # Quick verification that the SyncLog has the entry. Once push_file_now()
    # resolves, the append happened synchronously — a single read suffices,
    # but allow a brief poll in case CDP read-after-write is delayed.
    import json
    saw_entry = False
    for _ in range(10):
        entries_json = await cdp_a.evaluate(
            f"JSON.stringify({PLUGIN_PATH}.syncLog.entries().filter("
            f"e => e.action === 'push' && e.path.includes('SyncLog62')))"
        )
        entries = json.loads(entries_json) if isinstance(entries_json, str) else []
        if entries:
            saw_entry = True
            break
        await asyncio.sleep(0.2)
    assert saw_entry, (
        "No 'push' entry for SyncLog62 in plugin.syncLog after push_file_now() — "
        "the helper's syncLog.append() did not record. Inspect cdp.push_file_now."
    )

    try:
        # ------------------------------------------------------------------
        # Open the sync log modal via the registered command.
        # ------------------------------------------------------------------
        await cdp_a.run_command("show-sync-log")

        # Wait for the modal to mount.
        deadline_secs = 5
        for _ in range(deadline_secs * 10):
            present = await cdp_a.evaluate(
                "Boolean(document.querySelector('.engram-sync-log-modal'))"
            )
            if present:
                break
            await asyncio.sleep(0.1)
        else:
            pytest.fail("SyncLogModal did not mount within 5 s")

        # ------------------------------------------------------------------
        # Scrape all entry rows.  Each row is a div.engram-sync-log-entry
        # containing a <span> with text:
        #   "{time}  {icon} {action.padEnd(8)} {path}  {status}"
        # We read all span texts and look for one that contains both
        # "push" and the expected path fragment.
        # ------------------------------------------------------------------
        rows_json = await cdp_a.evaluate(
            "JSON.stringify(Array.from(document.querySelectorAll("
            "'.engram-sync-log-modal .engram-sync-log-entry span')).map("
            "el => el.textContent))"
        )
        import json as _json
        row_texts: list[str] = _json.loads(rows_json) if isinstance(rows_json, str) else []

        matching = [t for t in row_texts if "push" in t and "SyncLog62" in t]

        assert matching, (
            f"No push entry for 'SyncLog62' found in SyncLogModal.\n"
            f"All entry texts: {row_texts!r}"
        )

        # Confirm the expected path is present in the matched row.
        assert any("push-entry-test" in t for t in matching), (
            f"Push entry found for SyncLog62 dir but path 'push-entry-test' missing.\n"
            f"Matching rows: {matching!r}"
        )

    finally:
        # ------------------------------------------------------------------
        # Close any open modals via Escape.
        # ------------------------------------------------------------------
        await cdp_a.evaluate(
            """
            (() => {
                const modals = document.querySelectorAll('.modal-container .modal');
                for (const m of modals) {
                    m.dispatchEvent(new KeyboardEvent('keydown', {
                        key: 'Escape', bubbles: true,
                    }));
                }
            })()
            """
        )

        # Remove seeded file and sync to server.
        delete_note(vault_a, SEED_PATH)
        await cdp_a.trigger_full_sync()
