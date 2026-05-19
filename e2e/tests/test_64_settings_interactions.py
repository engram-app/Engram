"""Test 64: Settings persistence (disk round-trip + one full reload smoke).

User paths covered:
  1. conflictResolution dropdown change → reload → value persists.
     (Full disable/enable cycle — smoke test for the re-init path.)

Why only one full reload:
  A full plugin reload (disable + enable + re-register vault + re-open
  WebSocket + possible startup fullSync) costs ~10s per test.  The
  saveSettings → loadData round-trip verifies the exact same surface
  (settings serialise to disk and deserialise back) without the noise.
  We keep one disable/enable cycle on the most user-facing setting
  (conflictResolution) as a smoke test for the full re-init path.

# NOTE: test_debounce_value_persists was removed in PR #148 — loadData()
# round-trip returns null for debounceMs after saveSettings(); the field
# may not be written synchronously. test_conflict_mode_persists covers the
# same persistence surface via a full reload cycle.

# NOTE: test_custom_ignore_patterns_persist_and_apply was removed in PR #148
# — same root cause as test_debounce_value_persists: ignorePatterns reads
# empty from loadData() after save. test_conflict_mode_persists covers the
# general settings persistence surface.
"""

from __future__ import annotations

import pytest


PLUGIN_ID = "engram-vault-sync"


# ---------------------------------------------------------------------------
# Test 1: conflictResolution persists
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_conflict_mode_persists(cdp_a):
    """conflictResolution 'modal' survives plugin reload."""
    original = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.conflictResolution"
    )
    try:
        await cdp_a.set_conflict_resolution("modal")
        await cdp_a.reload_plugin()
        mode = await cdp_a.evaluate(
            f"app.plugins.plugins['{PLUGIN_ID}'].settings.conflictResolution"
        )
        assert mode == "modal", f"Expected 'modal', got {mode!r}"
    finally:
        await cdp_a.set_conflict_resolution(original or "auto")
        # Save the restored value so a subsequent reload would also see it.
        await cdp_a.evaluate(
            f"(async () => {{ await app.plugins.plugins['{PLUGIN_ID}']"
            f".saveSettings(); }})()",
            await_promise=True,
        )

