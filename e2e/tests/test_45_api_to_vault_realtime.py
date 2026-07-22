"""Test 45: REST API direct write → WebSocket broadcast → Obsidian vault receives in real-time."""

import logging
import time

import pytest

from helpers.vault import read_note, wait_for_content, wait_for_file, wait_for_file_gone
from helpers.latency import DELIVERY_TIMEOUT

logger = logging.getLogger(__name__)

RT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound; latency is recorded, not asserted


def _log_latency(label: str, t0: float) -> float:
    elapsed = time.monotonic() - t0
    logger.info("LATENCY [%s]: %.3fs", label, elapsed)
    return elapsed


@pytest.mark.asyncio
async def test_api_create_broadcasts_to_vault(vault_b, cdp_b, api_sync):
    """API creates a note → B receives it via WebSocket channel without manual pull."""
    path = "E2E/ApiCreateRT.md"
    content = "# API Create RT\nCreated directly via REST API"

    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    t0 = time.monotonic()
    api_sync.create_note(path, content)
    wait_for_file(vault_b, path, timeout=RT_TIMEOUT)
    _log_latency("api_create", t0)

    assert "Created directly via REST API" in read_note(vault_b, path)


@pytest.mark.asyncio
async def test_api_update_broadcasts_to_vault(vault_b, cdp_b, api_sync):
    """API updates an existing note → B receives the updated content via WebSocket."""
    path = "E2E/ApiUpdateRT.md"

    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    # Create initial version and wait for it to arrive
    api_sync.create_note(path, "# API Update RT\nVersion 1")
    wait_for_file(vault_b, path, timeout=RT_TIMEOUT)

    # Now update (upsert) and measure
    t0 = time.monotonic()
    api_sync.create_note(path, "# API Update RT\nVersion 2 — updated via API")
    wait_for_content(vault_b, path, "Version 2", timeout=RT_TIMEOUT)
    _log_latency("api_update", t0)

    assert "Version 2 — updated via API" in read_note(vault_b, path)


@pytest.mark.asyncio
async def test_api_delete_broadcasts_to_vault(vault_b, cdp_b, api_sync):
    """API deletes a note → B removes it from vault via WebSocket channel."""
    path = "E2E/ApiDeleteRT.md"

    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    # Create and wait for arrival
    api_sync.create_note(path, "# API Delete RT\nThis will be deleted")
    wait_for_file(vault_b, path, timeout=RT_TIMEOUT)

    # Delete and measure
    t0 = time.monotonic()
    api_sync.delete_note(path)
    wait_for_file_gone(vault_b, path, timeout=RT_TIMEOUT)
    _log_latency("api_delete", t0)
