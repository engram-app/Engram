"""Test 81: suite-wide remote logging is on by default.

Regression guard for the harness seed in helpers/obsidian.py
(``diagnosticsEnabled: True``). Unlike test_16, this test NEVER calls
``enable_remote_logging`` — the whole point is that every device already
ships client logs without a per-test opt-in, so a delivery flake's first
failing run carries client-side evidence (consumed by
helpers/log_oracle.py). If someone drops the seed, this fails loudly.
"""

import time

import pytest

from helpers.vault import write_note


@pytest.mark.asyncio
async def test_client_logs_ship_without_opt_in(vault_a, cdp_a, api_sync):
    # NOTE: no cdp_a.enable_remote_logging() — capture must be on from the seed.

    # Generate plugin activity so there is something to ship.
    write_note(vault_a, "E2E/Rlog81/trigger.md", "# Rlog81\nForce rlog entries")
    api_sync.wait_for_note("E2E/Rlog81/trigger.md")
    await cdp_a.trigger_full_sync()
    await cdp_a.flush_remote_logs()

    plugin_categories = {"push", "pull", "lifecycle", "channel", "ws"}
    plugin_logs = []
    logs = []
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        logs = api_sync.get_logs(limit=100).get("logs", [])
        plugin_logs = [
            l for l in logs
            if l.get("category") in plugin_categories and l.get("plugin_version")
        ]
        if plugin_logs:
            break
        await cdp_a.flush_remote_logs()

    assert len(plugin_logs) >= 1, (
        "Suite-wide remote logging appears OFF: no plugin-generated log shipped "
        "without an explicit enable_remote_logging() call. Check the "
        "diagnosticsEnabled seed in helpers/obsidian.py. "
        f"Categories seen: {[l.get('category') for l in logs]}"
    )
