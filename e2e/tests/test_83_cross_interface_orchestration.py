"""Test 83: one logical note traverses MCP → Obsidian → REST → Obsidian → MCP.

The orchestration test the suite never had: every hop is LIVE (no manual
pull), and the final read-back asserts all interfaces agree on the content.
"""

import uuid

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import read_note, wait_for_content, write_note
from helpers.latency import DELIVERY_TIMEOUT

pytestmark = pytest.mark.asyncio

PATH = f"E2E/Orchestra-{uuid.uuid4().hex[:12]}.md"
RT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound; latency is recorded, not asserted


def _mcp_text(response: dict) -> str:
    """Extract the text string from an MCP JSON-RPC result (mirrors test_46)."""
    return response["result"]["content"][0]["text"]


async def test_mcp_rest_obsidian_agree(vault_b, cdp_b, api_sync):
    # Hop 1 is MCP, so poll for the join ack like test_46 does (issue #161:
    # a one-shot check races the publish below while the channel is still
    # (re)joining after fixture/prior-test setup).
    await cdp_b.wait_for_stream_connected(timeout=RT_TIMEOUT)

    # Hop 1: MCP write_note → Obsidian receives live.
    # (create_note has no `path` arg — it derives the filename from `title`
    # via server-side auto-placement. write_note is the MCP tool that takes
    # an exact path, matching test_46's write_note case.)
    resp, status = api_sync.mcp_call(
        "write_note", {"path": PATH, "content": "# Orchestra\nv1 via MCP"}
    )
    assert status == 200 and "Note saved" in _mcp_text(resp), f"MCP write failed: {resp}"
    assert "v1 via MCP" in wait_for_delivery(vault_b, PATH, api_sync, timeout=RT_TIMEOUT)

    # Hop 2: REST edit → Obsidian receives live.
    api_sync.create_note(PATH, "# Orchestra\nv2 via REST")
    wait_for_content(vault_b, PATH, "v2 via REST", timeout=RT_TIMEOUT)

    # Hop 3: Obsidian edit → server, read back via REST and MCP.
    write_note(vault_b, PATH, "# Orchestra\nv3 via Obsidian")
    note = api_sync.wait_for_note_content(PATH, "v3 via Obsidian", timeout=RT_TIMEOUT)
    assert note is not None, "Obsidian push never reached the server"

    mcp_resp, status = api_sync.mcp_call("get_note", {"source_path": PATH})
    assert status == 200
    assert "v3 via Obsidian" in _mcp_text(mcp_resp), (
        "MCP read-back disagrees with what Obsidian pushed"
    )
    # And the vault still holds the final truth (no echo rewrote it).
    assert "v3 via Obsidian" in read_note(vault_b, PATH)
