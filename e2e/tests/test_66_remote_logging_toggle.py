"""Test 66: Remote logging toggle stops server flush when disabled.

User path covered:
  1. Enable remote logging via settings.diagnosticsEnabled = true.
  2. Log 25 entries via rlog() singleton (above the flush threshold of 20).
  3. Wait for auto-flush to deliver them to the server.
  4. Disable remote logging via settings.diagnosticsEnabled = false.
  5. Log 25 more entries tagged "after-disable".
  6. Wait the same interval — assert the after-disable entries do NOT appear
     on the server (logging is suppressed).

Implementation notes vs plan draft:
  - Remote logging is one facet of the single settings.diagnosticsEnabled toggle
    (plugin collapsed remoteLoggingEnabled/diagnosticMode/tracingEnabled into it,
    src/types.ts); saveSettings() gates rlog().setEnabled on it.
  - Plan used plugin.remoteLog?.info() — the rlog singleton is module-level
    (src/remote-log.ts), not a property on the plugin instance.  We access it
    via app.plugins.plugins['engram-vault-sync'].syncEngine (which indirectly
    uses rlog), but for explicit log injection we call the module export via
    the require() shim: require('engram-vault-sync/remote-log').rlog().info()
    is not available in the Obsidian bundle.  Instead we use the CDP helper
    enable_remote_logging() to ensure the flag is on, then trigger a real sync
    to generate server-observable entries before and after toggling.
  - The backend /logs endpoint has no full-text query param (only level,
    category, since).  Attribution is done Python-side — but by DEVICE ID, not
    by substring: `noteRef()` replaces every path in a log message with an
    opaque label (`n106`) so vault paths never reach a hosted aggregator, so
    grepping for a note path can never match. Rows carry `device_id`
    (logs_controller.ex); see ApiClient.list_logs() in helpers/api.py.
  - The flush threshold for rlog is 20 entries (src/remote-log.ts).  We generate
    25 entries per phase to reliably exceed it.
  - Both phases read with `since` AND `device_id`. The e2e vault is
    session-scoped and shared by ~110 tests logging under one account, so an
    unfiltered read is mostly other tests' rows — which made the assert-zero
    below pass for free regardless of whether the toggle worked.
"""

from __future__ import annotations

import asyncio
from datetime import datetime, timezone

import pytest

from helpers.vault import write_note


PLUGIN_ID = "engram-vault-sync"
# Unique marker string embedded in log messages generated after the toggle.
AFTER_MARKER = "test66-after-disable"


async def _set_remote_logging(cdp, enabled: bool) -> None:
    """Toggle remote logging on one instance via saveSettings.

    Remote logging is a facet of the single ``diagnosticsEnabled`` toggle (the
    plugin collapsed remoteLoggingEnabled/diagnosticMode/tracingEnabled into it);
    saveSettings() gates rlog().setEnabled on ``diagnosticsEnabled``.
    """
    await cdp.evaluate(
        f"(async () => {{"
        f"  const p = app.plugins.plugins['{PLUGIN_ID}'];"
        f"  p.settings.diagnosticsEnabled = {str(enabled).lower()};"
        f"  await p.saveSettings();"
        f"}})()",
        await_promise=True,
    )


@pytest.mark.asyncio
async def test_disable_stops_flush(vault_a, cdp_a, cdp_b, api_sync):
    """Logs generated after diagnosticsEnabled=false do not reach the server.

    Both sync-pair instances are toggled. Remote logging is seeded ON
    suite-wide (helpers/obsidian.py, backend #909), so instance B also logs the
    receive side of after.md under the SHARED user.

    device_id HAS landed — every row carries it (logs_controller.ex) — so the
    reads below attribute to instance A specifically. B is still silenced,
    because a full sync between the pair is not the thing under test; the
    stronger "A goes silent while B keeps logging" variant is now possible and
    is the natural next step.
    """
    # ------------------------------------------------------------------ #
    # Setup: capture original setting on both instances.
    # ------------------------------------------------------------------ #
    original_enabled_a = await cdp_a.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.diagnosticsEnabled"
    )
    original_enabled_b = await cdp_b.evaluate(
        f"app.plugins.plugins['{PLUGIN_ID}'].settings.diagnosticsEnabled"
    )

    try:
        # Enable remote logging. enable_remote_logging() awaits saveSettings
        # which is enough — no extra sleep needed.
        await cdp_a.enable_remote_logging()

        # Bound every /logs read below to THIS test's window.
        #
        # `query=` is a client-side substring filter over whatever /logs
        # returns, and /logs returns the most recent `limit` rows for the USER.
        # The e2e vault is session-scoped and shared by ~110 tests, all logging
        # under one account, so a 200-row window is a few seconds of somebody
        # else's `gap-heal replay` and `rename-trace` noise — this test's own
        # entries sit far below it and the filter finds nothing.
        #
        # That is why this looked like a delivery flake for so long: the
        # assertion said "no entries reached the server" while the server held
        # a full page of entries. `since` is a real backend param; use it.
        since = datetime.now(timezone.utc).isoformat()

        # Attribute rows to THIS instance. Every log row carries `device_id`
        # (logs_controller.ex) — the docstring's "no per-instance device_id"
        # note is stale.
        device_a = await cdp_a.evaluate(f"app.plugins.plugins['{PLUGIN_ID}'].deviceId")
        assert device_a, "Instance A has no deviceId; cannot attribute log rows to it."

        # ------------------------------------------------------------------ #
        # Phase 1: generate entries BEFORE disabling — verify they reach the
        # server so we know the pipeline is working, not just suppressed.
        # ------------------------------------------------------------------ #
        before_marker = "test66-before-disable"
        # Deterministically push a note via the engine — generates rlog
        # entries on the push code path. push_file_now bypasses the watcher
        # debounce so the rlog calls land synchronously.
        #
        # NOTE: we do NOT match on the note path. `noteRef()` (src/note-ref.ts)
        # replaces every path in a log message with an opaque label — `n106`,
        # `n119` — precisely so vault paths never reach a hosted aggregator.
        # This test used to grep for "E2E/Logging66/before.md" on the premise
        # that "the sync engine includes the path when it logs push/pull
        # events". It does not, and cannot. That is why phase 1 failed: not a
        # delivery flake, a marker that can never match.
        await cdp_a.push_file_now(
            "E2E/Logging66/before.md",
            f"# {before_marker}\nbefore content",
        )
        # Force flush (simulate page hide), and RE-flush on every poll
        # iteration until the entries land.
        #
        # An earlier version flushed exactly once, arguing "the flush already
        # happened, and a real 5 s server-side latency is a separate bug worth
        # surfacing as a fail". That reasoning is wrong, and it is why this
        # test was the suite's most persistent flake (#1421).
        #
        # rlog only auto-flushes at FLUSH_THRESHOLD = 20 buffered entries
        # (src/remote-log.ts). One small note generates far fewer, so the
        # single manual flush is the ONLY thing that can deliver them. Two
        # ways that one shot is lost, neither of which server-polling can
        # recover from:
        #
        #   * the visibilitychange handler fires before pushFile's rlog calls
        #     have been buffered — flush() finds an empty buffer, sends
        #     nothing, and nothing ever flushes again;
        #   * the POST fails transiently. flush() deliberately puts the
        #     entries BACK on the buffer for a later flush — but there is no
        #     later flush, so they sit there until the process ends.
        #
        # Re-flushing is idempotent (an empty buffer is a no-op) and costs one
        # CDP round trip per iteration. It cannot mask real server latency
        # either: the deadline is unchanged, so a genuinely slow server still
        # fails here.
        before_logs: list = []
        flushes = 0
        deadline_before = asyncio.get_event_loop().time() + 15
        while asyncio.get_event_loop().time() < deadline_before:
            await cdp_a.flush_remote_logs()
            flushes += 1
            before_logs = api_sync.list_logs(limit=200, since=since, device_id=device_a)
            if before_logs:
                break
            await asyncio.sleep(0.25)

        # `query=` is a CLIENT-SIDE substring match on the message field
        # (helpers/api.py list_logs) — the backend has no full-text filter. So
        # "no matching rows" has two very different causes and the assertion
        # must distinguish them, or it keeps blaming delivery for what is
        # actually a changed log message.
        if not before_logs:
            any_logs = api_sync.list_logs(limit=200, since=since)
            devices = sorted({str(entry.get("device_id")) for entry in any_logs})
            sample = [str(entry.get("message", ""))[:120] for entry in any_logs[:10]]
            assert before_logs, (
                f"No log rows from instance A (device {device_a}) after "
                f"{flushes} flush attempts over 15 s, though the server holds "
                f"{len(any_logs)} row(s) for this user since the test started.\n"
                f"  - {len(any_logs)} > 0 with A absent means A specifically is "
                f"not delivering: rlog disabled, buffer empty, or its POST "
                f"/logs failing (flush() re-buffers on failure, so every "
                f"attempt retried).\n"
                f"  - {len(any_logs)} == 0 means nothing is arriving for anyone "
                f"— suspect the endpoint, not the plugin.\n"
                f"Devices seen: {devices}\n"
                f"Most recent messages: {sample}"
            )

        # ------------------------------------------------------------------ #
        # Phase 2: disable remote logging on BOTH sync-pair instances.
        # saveSettings() calls rlog().setEnabled(false) synchronously, so no
        # settle sleep is required. B must be silenced too (see docstring):
        # it logs after.md's receive events under the same user.
        # ------------------------------------------------------------------ #
        await _set_remote_logging(cdp_a, False)
        await _set_remote_logging(cdp_b, False)

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
        # The phase-2 window opens BEFORE the work that would generate rows and
        # AFTER the toggle, so phase 1's own rows cannot satisfy an assert-zero
        # whose whole job is to prove silence.
        after_since = datetime.now(timezone.utc).isoformat()
        await cdp_a.trigger_full_sync()
        # Attempt a flush — should be a no-op because rlog is disabled.
        # flush_remote_logs() waits 600 ms internally; that's enough time
        # for any rogue POST to land before we query the server.
        await cdp_a.flush_remote_logs()

        # Check that no after-disable marker entries reached the server.
        #
        # This is the test's ACTUAL claim, and it is an assert-ZERO — which
        # passes for free the moment the query stops being able to find
        # anything. Before `since` was added, the 200-row window was full of
        # other tests' logs, so this assertion held whether or not the toggle
        # worked. The phase-1 assertion above is what keeps it honest: it
        # proves the same query DOES find this test's own entries when logging
        # is on, using the same window. Do not weaken one without the other.
        after_logs = api_sync.list_logs(limit=200, since=after_since, device_id=device_a)

        # `forced` rows are EXEMPT, and that is the contract — not a concession.
        #
        # RemoteLogger.anomaly() ships with force: true on purpose: a fresh
        # install has diagnostics OFF and is the install most likely to hit a
        # first-sync bug (prod 2026-08-13, 316 of 316 notes dropped with zero
        # client logs to read). Those entries carry counts and slugs only —
        # never a path, title or content — so the setting still protects what it
        # is meant to.
        #
        # Asserting a flat zero here made this test fail ~2/3 of runs on main,
        # because a post-toggle sync legitimately emits
        # `replay_produced_no_files`. It was nearly misdiagnosed as telemetry
        # shipping after opt-out. See engram-app/Engram#1598.
        #
        # What must still hold is that ORDINARY logging stopped, so the
        # assertion narrows rather than weakens: zero non-forced rows.
        unforced = [row for row in after_logs if not row.get("forced")]
        assert len(unforced) == 0, (
            f"Expected 0 NON-FORCED log rows from instance A (device {device_a}) "
            f"after disabling remote logging, but got {len(unforced)}: {unforced!r}\n"
            f"(forced anomaly rows are exempt by contract; {len(after_logs) - len(unforced)} "
            f"of the {len(after_logs)} rows in the window were forced)"
        )

    finally:
        # ------------------------------------------------------------------ #
        # Restore: reset diagnosticsEnabled on both instances, clean up
        # seeded notes.
        # ------------------------------------------------------------------ #
        await _set_remote_logging(cdp_a, bool(original_enabled_a))
        await _set_remote_logging(cdp_b, bool(original_enabled_b))
        for fname in ("before.md", "after.md"):
            path = vault_a / "E2E" / "Logging66" / fname
            path.unlink(missing_ok=True)
        await cdp_a.trigger_full_sync()
