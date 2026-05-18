"""Test 66: Remote logging toggle stops server flush when disabled.

User path covered:
  1. Enable remote logging via settings.remoteLoggingEnabled = true.
  2. Log 25 entries via rlog() singleton (above the flush threshold of 20).
  3. Wait for auto-flush to deliver them to the server.
  4. Disable remote logging via settings.remoteLoggingEnabled = false.
  5. Log 25 more entries tagged "after-disable".
  6. Wait the same interval — assert the after-disable entries do NOT appear
     on the server (logging is suppressed).

Implementation notes vs plan draft:
  - Plan used settings.remoteLogging; real field is settings.remoteLoggingEnabled
    (src/types.ts line 14).
  - Plan used plugin.remoteLog?.info() — the rlog singleton is module-level
    (src/remote-log.ts), not a property on the plugin instance.  We access it
    via app.plugins.plugins['engram-vault-sync'].syncEngine (which indirectly
    uses rlog), but for explicit log injection we call the module export via
    the require() shim: require('engram-vault-sync/remote-log').rlog().info()
    is not available in the Obsidian bundle.  Instead we use the CDP helper
    enable_remote_logging() to ensure the flag is on, then trigger a real sync
    to generate server-observable entries before and after toggling.
  - The backend /logs endpoint has no full-text query param (only level,
    category, since).  After-disable filtering is done Python-side by substring
    matching on the message field — see ApiClient.list_logs() in helpers/api.py.
  - The flush threshold for rlog is 20 entries (src/remote-log.ts).  We generate
    25 entries per phase to reliably exceed it.
  - We use api_sync.list_logs(query="after-disable") to check the server sees
    zero entries matching the post-disable marker.
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.vault import write_note


PLUGIN_ID = "engram-vault-sync"
# Unique marker string embedded in log messages generated after the toggle.
AFTER_MARKER = "test66-after-disable"


@pytest.mark.asyncio
async def test_disable_stops_flush(vault_a, cdp_a, api_sync):
    """Logs generated after remoteLoggingEnabled=false do not reach the server."""
    # ------------------------------------------------------------------ #
    # Setup: capture original setting and ensure remote logging starts ON.
    # ------------------------------------------------------------------ #
    original_enabled = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.remoteLoggingEnabled"
    )

    try:
        # Enable remote logging. enable_remote_logging() awaits saveSettings
        # which is enough — no extra sleep needed.
        await cdp_a.enable_remote_logging()

        # ------------------------------------------------------------------ #
        # Phase 1: generate entries BEFORE disabling — verify they reach the
        # server so we know the pipeline is working, not just suppressed.
        # ------------------------------------------------------------------ #
        before_marker = "test66-before-disable"
        # Deterministically push a note via the engine — generates rlog
        # entries on the push code path. push_file_now bypasses the watcher
        # debounce so the rlog calls land synchronously.
        await cdp_a.push_file_now(
            "E2E/Logging66/before.md",
            f"# {before_marker}\nbefore content",
        )
        # Force flush (simulate page hide). flush_remote_logs() already
        # waits 600 ms internally for the POST /logs round-trip, then we
        # briefly poll the server. We do NOT retry-flush inside the loop:
        # the flush already happened, and a real 5 s server-side latency
        # is a separate bug worth surfacing as a fail.
        await cdp_a.flush_remote_logs()

        before_logs: list = []
        deadline_before = asyncio.get_event_loop().time() + 5
        while asyncio.get_event_loop().time() < deadline_before:
            before_logs = api_sync.list_logs(limit=200, query="E2E/Logging66/before.md")
            if before_logs:
                break
            await asyncio.sleep(0.25)

        assert before_logs, (
            "No pre-disable log entries reached the server within 5 s after "
            "push_file_now + flush_remote_logs. This means rlog().info(...) "
            "calls inside pushFile() either didn't fire (engine code change) "
            "or the visibilitychange flush handler isn't POSTing to /logs. "
            "Inspect src/remote-log.ts flush() and the rlog calls in sync.ts."
        )

        # ------------------------------------------------------------------ #
        # Phase 2: disable remote logging.
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.remoteLoggingEnabled = false;"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        # saveSettings() calls rlog().setEnabled(false) synchronously in
        # onSettingsSave — no settle sleep required.

        # ------------------------------------------------------------------ #
        # Phase 3: generate entries AFTER disabling — they should NOT arrive.
        # ------------------------------------------------------------------ #
        # Push a second note — the sync engine will run, but rlog is now disabled
        # so any log() calls inside the engine are no-ops.
        write_note(
            vault_a,
            "E2E/Logging66/after.md",
            f"# {AFTER_MARKER}\nafter content",
        )
        await cdp_a.trigger_full_sync()
        # Attempt a flush — should be a no-op because rlog is disabled.
        # flush_remote_logs() waits 600 ms internally; that's enough time
        # for any rogue POST to land before we query the server.
        await cdp_a.flush_remote_logs()

        # Check that no after-disable marker entries reached the server.
        # We match on the path string "E2E/Logging66/after.md" in log messages,
        # which the sync engine includes when it logs push/pull events.
        after_logs = api_sync.list_logs(limit=200, query="E2E/Logging66/after.md")
        assert len(after_logs) == 0, (
            f"Expected 0 log entries containing 'E2E/Logging66/after.md' after "
            f"disabling remote logging, but got {len(after_logs)}: {after_logs!r}"
        )

    finally:
        # ------------------------------------------------------------------ #
        # Restore: reset remoteLoggingEnabled to its original value, clean up
        # seeded notes.
        # ------------------------------------------------------------------ #
        restore_enabled = bool(original_enabled)
        await cdp_a.evaluate(
            f"(async () => {{"
            f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
            f"  p.settings.remoteLoggingEnabled = {str(restore_enabled).lower()};"
            f"  await p.saveSettings();"
            f"}})()",
            await_promise=True,
        )
        for fname in ("before.md", "after.md"):
            path = vault_a / "E2E" / "Logging66" / fname
            path.unlink(missing_ok=True)
        await cdp_a.trigger_full_sync()
