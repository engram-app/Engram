"""Test 16: Remote logging pipeline — end-to-end through plugin and API.

Two test paths:
1. Plugin-driven E2E: enable remote logging via CDP → trigger sync (generates
   rlog entries) → flush → verify logs arrive via GET /logs.
2. API-only integration: direct POST /logs → GET /logs to validate backend
   ingest, retrieval, field presence, and level filtering.
3. Multi-tenant isolation: user C cannot see sync-user's logs.
"""

import time
from datetime import datetime, timezone

import pytest

from helpers.vault import write_note


def _now_iso() -> str:
    """Current UTC timestamp in ISO 8601 for log entries."""
    return datetime.now(timezone.utc).isoformat()


@pytest.mark.asyncio
async def test_remote_logging_plugin_pipeline(vault_a, cdp_a, api_sync):
    """Plugin rlog entries flow through flush → POST /logs → GET /logs."""
    # Enable remote logging through the real plugin settings path
    await cdp_a.enable_remote_logging()

    # Create a note to trigger push → generates rlog entries
    # (push start, push ok, etc.)
    write_note(vault_a, "E2E/Rlog16/trigger.md", "# Rlog trigger\nForce rlog entries")
    api_sync.wait_for_note("E2E/Rlog16/trigger.md", timeout=15)

    # Trigger a full sync — generates pull started/done rlog entries
    await cdp_a.trigger_full_sync()

    # Force flush via visibilitychange simulation
    await cdp_a.flush_remote_logs()

    # Poll GET /logs for plugin-generated entries (retry for timing)
    plugin_categories = {"push", "pull", "lifecycle", "channel"}
    plugin_logs = []
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        logs_resp = api_sync.get_logs(limit=100)
        logs = logs_resp.get("logs", [])
        plugin_logs = [
            l for l in logs
            if l.get("category") in plugin_categories
            and l.get("plugin_version")
        ]
        if plugin_logs:
            break
        # Retry flush in case first attempt hit a timing edge
        await cdp_a.flush_remote_logs()

    assert len(plugin_logs) >= 1, (
        f"Expected at least 1 plugin-generated rlog entry, got {len(plugin_logs)}. "
        f"All log categories: {[l.get('category') for l in logs]}"
    )

    # Verify rlog entry fields match RemoteLogEntry shape
    for log in plugin_logs:
        assert "id" in log, "Log entry should have id"
        assert "ts" in log, "Log entry should have timestamp"
        assert log["level"] in ("info", "warn", "error"), f"Bad level: {log['level']}"
        assert log.get("platform") in ("desktop", "mobile"), f"Bad platform: {log.get('platform')}"
        assert log.get("plugin_version"), "Plugin-generated log must have plugin_version"


@pytest.mark.asyncio
async def test_remote_logging_api_ingest(api_sync):
    """API-only: POST /logs ingest and GET /logs retrieval work correctly.

    This validates the backend endpoints in isolation. Plugin flush path
    is tested separately in test_remote_logging_plugin_pipeline.
    """
    marker = "e2e-test-16-api-marker"

    # Ingest a batch with info + warn levels (use current timestamps to
    # avoid being pushed out of the result window by plugin rlog entries)
    status = api_sync.ingest_logs([
        {
            "ts": _now_iso(),
            "level": "info",
            "category": "sync",
            "message": f"Test log entry 1 — {marker}",
            "plugin_version": "0.6.0",
            "platform": "desktop",
        },
        {
            "ts": _now_iso(),
            "level": "warn",
            "category": "lifecycle",
            "message": f"Test warning — {marker}",
            "plugin_version": "0.6.0",
            "platform": "desktop",
        },
    ])
    assert status == 200, f"Log ingest should succeed, got {status}"

    # Retrieve logs (high limit to avoid being crowded out by plugin rlog entries)
    logs_resp = api_sync.get_logs(limit=200)
    logs = logs_resp.get("logs", [])
    marker_logs = [l for l in logs if marker in l.get("message", "")]

    assert len(marker_logs) >= 2, (
        f"Expected at least 2 marker logs, got {len(marker_logs)}. "
        f"All logs: {[l.get('message', '')[:60] for l in logs]}"
    )

    # Verify log fields
    for log in marker_logs:
        assert "id" in log, "Log entry should have id"
        assert "ts" in log, "Log entry should have timestamp"
        assert log["level"] in ("info", "warn", "error"), f"Bad level: {log['level']}"
        assert log.get("category") in ("sync", "lifecycle"), f"Bad category: {log.get('category')}"

    # Verify level filter works
    warn_resp = api_sync.get_logs(level="warn", limit=200)
    warn_logs = [l for l in warn_resp.get("logs", []) if marker in l.get("message", "")]
    assert len(warn_logs) >= 1, "Should find at least 1 warn-level marker log"
    assert all(l["level"] == "warn" for l in warn_logs), "Level filter should only return warn"


@pytest.mark.asyncio
async def test_remote_logging_isolation(api_sync, api_iso):
    """User C cannot see sync-user's logs."""
    # Seed a log for sync-user (current timestamp to stay in result window)
    api_sync.ingest_logs([{
        "ts": _now_iso(),
        "level": "info",
        "category": "sync",
        "message": "isolation-check-16",
        "platform": "desktop",
    }])

    # sync-user sees their logs
    sync_logs = api_sync.get_logs(limit=200)
    assert any("isolation-check-16" in l.get("message", "") for l in sync_logs.get("logs", [])), \
        "sync-user should see their own log"

    # isolation-user should NOT see them
    iso_logs = api_iso.get_logs(limit=200)
    iso_messages = [l.get("message", "") for l in iso_logs.get("logs", [])]
    assert not any("isolation-check-16" in m for m in iso_messages), \
        "isolation-user must not see sync-user's logs"
