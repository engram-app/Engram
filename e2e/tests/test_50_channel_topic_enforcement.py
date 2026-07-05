"""Test 50: Channel topic format enforcement + stream connectivity checks.

Regression tests for the backend change that removed the legacy
sync:{user_id} backwards-compat topic. Only sync:{user_id}:{vault_id}
is accepted now.

Also verifies that the plugin's WebSocket stream correctly connects with
the vault-scoped topic and that connectivity checks report accurate state.
"""

from __future__ import annotations

import asyncio
import logging
import time

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import write_note

logger = logging.getLogger(__name__)

RT_TIMEOUT = 10


@pytest.mark.asyncio
async def test_stream_connects_with_vault_topic(cdp_a, cdp_b):
    """Both A and B plugins connect their WebSocket channels successfully.

    Proves the plugin joins sync:{user_id}:{vault_id} (not the removed
    sync:{user_id} topic) and the backend accepts it.
    """
    # Wait for both to connect (may need a moment after prior tests)
    for _ in range(20):
        a_ok = await cdp_a.check_stream_connected()
        b_ok = await cdp_b.check_stream_connected()
        if a_ok and b_ok:
            break
        await asyncio.sleep(0.5)

    assert await cdp_a.check_stream_connected(), "A's channel should be connected"
    assert await cdp_b.check_stream_connected(), "B's channel should be connected"


@pytest.mark.asyncio
async def test_stream_reports_disconnected_after_drop(cdp_b):
    """After explicit disconnect, isLiveConnected reports false.

    Verifies the status tracking is accurate (not stale).
    """
    # Ensure connected first
    for _ in range(20):
        if await cdp_b.check_stream_connected():
            break
        await asyncio.sleep(0.5)
    assert await cdp_b.check_stream_connected()

    # Disconnect
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)

    assert not await cdp_b.check_stream_connected(), (
        "isLiveConnected should be false after disconnect"
    )

    # Reconnect for subsequent tests and wait for it to complete
    await cdp_b.reconnect_stream()
    for _ in range(20):
        if await cdp_b.check_stream_connected():
            break
        await asyncio.sleep(0.5)


@pytest.mark.asyncio
async def test_reconnect_rejoins_correct_topic(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """After disconnect + reconnect, channel still works (correct topic re-joined).

    This catches regressions where reconnect might try the old topic format.
    """
    # Ensure B is connected
    for _ in range(20):
        if await cdp_b.check_stream_connected():
            break
        await asyncio.sleep(0.5)
    assert await cdp_b.check_stream_connected()

    # Disconnect B
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)

    # Reconnect B
    await cdp_b.reconnect_stream()

    # Verify channel is functional by pushing a note through it
    path = "E2E/TopicReconnectCheck.md"
    content = "# Topic Reconnect\nVerifying channel works after reconnect"
    write_note(vault_a, path, content)
    api_sync.wait_for_note(path, timeout=10)

    # B should receive via the reconnected channel
    t0 = time.monotonic()
    b_content = wait_for_delivery(vault_b, path, api_sync, timeout=RT_TIMEOUT)
    elapsed = time.monotonic() - t0
    logger.info("LATENCY [topic_reconnect]: %.3fs", elapsed)

    assert "Verifying channel works after reconnect" in b_content


@pytest.mark.asyncio
async def test_live_sync_still_works_after_all_tests(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Smoke test: basic live sync still works.

    Guards against test pollution — if earlier tests leaked state or broke
    auth, this catches it. NOTE: under xdist --dist=loadfile the four tests in
    this file stay co-located on one worker but run in collection order, so
    this fires mid-suite (not literally last) — it is a live-sync smoke check,
    not a guaranteed after-everything canary.
    """
    for _ in range(20):
        a_ok = await cdp_a.check_stream_connected()
        b_ok = await cdp_b.check_stream_connected()
        if a_ok and b_ok:
            break
        await asyncio.sleep(0.5)

    assert await cdp_a.check_stream_connected(), "A's channel broken after prior tests"
    assert await cdp_b.check_stream_connected(), "B's channel broken after prior tests"

    path = "E2E/SmokeAfterTests.md"
    content = "# Smoke Test\nLive sync still works after all E2E tests"
    write_note(vault_a, path, content)
    api_sync.wait_for_note(path, timeout=10)

    b_content = wait_for_delivery(vault_b, path, api_sync, timeout=RT_TIMEOUT)
    assert "Live sync still works" in b_content
