"""Test 56: Sync Center — too_large issue category + Ignore action.

Flow:
  1. Write an 11 MB note to vault_a — triggers push → server returns 413.
  2. Call trigger_full_sync() so the engine records the too_large issue.
  3. Open Sync Center and confirm a group whose category heading starts with
     "Too large" is present, containing the test note path.
  4. Click the "Ignore" action on that row.
  5. Confirm the row disappears from Issues and appears in the Ignored panel.

Cleanup (finally block):
  - click_restore_ignored() — removes from ignoredFiles so it doesn't bleed
    into other tests.
  - Delete the local file (it is never on the server — 413 was rejected).
  - trigger_full_sync() — lets the engine reconcile its state.

Requires a plugin build that ships the Sync Center (has_sync_center() guard).
"""

from __future__ import annotations

import asyncio
import time
import pytest

from helpers.vault import write_note, delete_note


SEED_DIR = "E2E/SyncCenter56"
NOTE_PATH = f"{SEED_DIR}/TooLarge.md"

# 11 MB of content — server limit is 5 MB, so this is well over the threshold.
# Using a repeating ASCII pattern avoids pathological compression artefacts.
_11MB_CONTENT = "# Too-Large Note\n" + ("x" * (11 * 1024 * 1024))


async def _wait_for_issue(cdp, path: str, timeout: float = 30) -> list[dict]:
    """Poll get_issue_groups() until an issue for `path` appears.

    Returns the full groups list once the issue is found.
    Raises TimeoutError if the issue never surfaces.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        groups = await cdp.get_issue_groups()
        for group in groups:
            for item in group.get("items", []):
                if item.get("path") == path:
                    return groups
        await asyncio.sleep(0.5)
    raise TimeoutError(
        f"Issue for '{path}' did not appear in Sync Center within {timeout}s"
    )


@pytest.mark.asyncio
async def test_too_large_issue_ignore(vault_a, cdp_a):
    """11 MB note → fullSync → too_large issue appears → Ignore → Ignored panel."""
    wrote = False
    try:
        # ── 1. Write the oversized note ──────────────────────────────────────
        write_note(vault_a, NOTE_PATH, _11MB_CONTENT)
        wrote = True

        # ── 2. Full sync so the engine pushes and records the 413 rejection ──
        # Accept the sync gate first: an upstream auth-swap test (test_47/48/49)
        # sharing this session-scoped instance can leave the gate closed
        # (syncBlocked), which makes fullSync short-circuit {pulled:0,pushed:0}
        # — the 413 never fires and no too_large issue is recorded (#915). Assert
        # the precondition here rather than trusting a neighbor's cleanup.
        await cdp_a.accept_sync_gate()
        await cdp_a.trigger_full_sync()

        # ── 3. Open Sync Center ───────────────────────────────────────────────
        await cdp_a.open_sync_center()

        # Poll until the issue appears (engine may need a moment to record it).
        groups = await _wait_for_issue(cdp_a, NOTE_PATH)

        # Find the group whose heading starts with "Too large"
        too_large_groups = [
            g for g in groups
            if g.get("category", "").startswith("Too large")
        ]
        assert too_large_groups, (
            f"Expected a 'Too large' issue group; got categories: "
            f"{[g.get('category') for g in groups]}"
        )

        group = too_large_groups[0]
        paths_in_group = [item["path"] for item in group.get("items", [])]
        assert NOTE_PATH in paths_in_group, (
            f"Expected {NOTE_PATH!r} in too_large group; found: {paths_in_group}"
        )

        # Confirm "Ignore" button is available on the row
        item = next(i for i in group["items"] if i["path"] == NOTE_PATH)
        assert "Ignore" in item.get("actions", []), (
            f"Expected 'Ignore' action on too_large row; actions: {item.get('actions')}"
        )

        # ── 4. Click Ignore ───────────────────────────────────────────────────
        await cdp_a.click_issue_action(NOTE_PATH, "Ignore")

        # Give the UI a moment to refresh (ignoreFilePermanently → refresh())
        await asyncio.sleep(0.5)

        # ── 5a. Confirm row is gone from Issues ───────────────────────────────
        groups_after = await cdp_a.get_issue_groups()
        for g in groups_after:
            if g.get("category", "").startswith("Too large"):
                remaining = [i["path"] for i in g.get("items", [])]
                assert NOTE_PATH not in remaining, (
                    f"{NOTE_PATH!r} still appears in Issues after Ignore"
                )

        # ── 5b. Confirm row appears in Ignored panel ──────────────────────────
        ignored = await cdp_a.get_ignored_files()
        assert NOTE_PATH in ignored, (
            f"Expected {NOTE_PATH!r} in Ignored panel; got: {ignored}"
        )

    finally:
        # ── Cleanup ───────────────────────────────────────────────────────────
        # 1. Remove from ignored list (so subsequent tests aren't affected)
        try:
            await cdp_a.click_restore_ignored(NOTE_PATH)
            await asyncio.sleep(0.3)
        except Exception:
            pass  # Row may not be present if test failed before Ignore click

        # 2. Delete local file (never reached server — 413 rejection)
        if wrote:
            delete_note(vault_a, NOTE_PATH)

        # 3. Re-sync so engine state matches reality
        try:
            await cdp_a.trigger_full_sync()
        except Exception:
            pass
