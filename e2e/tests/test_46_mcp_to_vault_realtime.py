"""Test 46: MCP tool call → WebSocket broadcast → Obsidian vault receives in real-time."""

import logging
import re
import time

import pytest

from helpers.vault import read_note, wait_for_file, wait_for_file_gone

logger = logging.getLogger(__name__)

RT_TIMEOUT = 8  # seconds — tight enough to prove real-time, loose enough for CI


def _log_latency(label: str, t0: float) -> float:
    elapsed = time.monotonic() - t0
    logger.info("LATENCY [%s]: %.3fs", label, elapsed)
    return elapsed


def _mcp_text(response: dict) -> str:
    """Extract the text string from an MCP JSON-RPC result."""
    return response["result"]["content"][0]["text"]


@pytest.mark.asyncio
async def test_mcp_write_note_broadcasts_to_vault(vault_b, cdp_b, api_sync):
    """MCP write_note → B receives the note via WebSocket channel."""
    path = "E2E/McpWriteRT.md"
    content = "# MCP Write RT\nCreated via MCP write_note tool"

    # Poll until the channel's join is acked (isLiveConnected flips true only on
    # the phx_join reply) — a one-shot check races the publish below when the
    # channel is still (re)joining after fixture/prior-test setup (issue #161).
    await cdp_b.wait_for_stream_connected(timeout=RT_TIMEOUT)

    t0 = time.monotonic()
    resp, status = api_sync.mcp_call("write_note", {"path": path, "content": content})
    assert status == 200
    assert "Note saved" in _mcp_text(resp)

    wait_for_file(vault_b, path, timeout=RT_TIMEOUT)
    _log_latency("mcp_write_note", t0)

    assert "Created via MCP write_note tool" in read_note(vault_b, path)


@pytest.mark.asyncio
async def test_mcp_create_note_broadcasts_to_vault(vault_b, cdp_b, api_sync):
    """MCP create_note with suggested_folder → B receives at server-chosen path."""
    # Poll until the channel's join is acked (isLiveConnected flips true only on
    # the phx_join reply) — a one-shot check races the publish below when the
    # channel is still (re)joining after fixture/prior-test setup (issue #161).
    await cdp_b.wait_for_stream_connected(timeout=RT_TIMEOUT)

    t0 = time.monotonic()
    resp, status = api_sync.mcp_call(
        "create_note",
        {
            "title": "MCP Create RT",
            "content": "Created via MCP create_note tool",
            "suggested_folder": "E2E",
        },
    )
    assert status == 200
    text = _mcp_text(resp)
    assert "Note created" in text

    # Extract path from "Note created: E2E/MCP Create RT.md"
    match = re.search(r"Note created: (.+)", text)
    assert match, f"Could not extract path from MCP response: {text}"
    path = match.group(1)

    wait_for_file(vault_b, path, timeout=RT_TIMEOUT)
    _log_latency("mcp_create_note", t0)

    assert "Created via MCP create_note tool" in read_note(vault_b, path)


@pytest.mark.asyncio
async def test_mcp_delete_broadcasts_to_vault(vault_b, cdp_b, api_sync):
    """MCP delete_note → B removes file from vault via WebSocket channel."""
    path = "E2E/McpDeleteRT.md"

    # Poll until the channel's join is acked (isLiveConnected flips true only on
    # the phx_join reply) — a one-shot check races the publish below when the
    # channel is still (re)joining after fixture/prior-test setup (issue #161).
    await cdp_b.wait_for_stream_connected(timeout=RT_TIMEOUT)

    # Pre-create via MCP and wait for arrival
    resp, status = api_sync.mcp_call(
        "write_note", {"path": path, "content": "# MCP Delete RT\nTo be deleted"}
    )
    assert status == 200
    wait_for_file(vault_b, path, timeout=RT_TIMEOUT)

    # Delete and measure
    t0 = time.monotonic()
    resp, status = api_sync.mcp_call("delete_note", {"path": path})
    assert status == 200
    assert "Note deleted" in _mcp_text(resp)

    wait_for_file_gone(vault_b, path, timeout=RT_TIMEOUT)
    _log_latency("mcp_delete", t0)
