"""Test 106: MCP delete_folder, then restore_deleted, brings the files back.

Safer delete (#609). An agent deletes a folder through MCP; the connected
Obsidian trashes the files live. One restore_deleted call with the returned
delete_op_id must bring every note and the attachment back on that same
device, with their content, and with no conflict copy or duplicate: the
restore keeps each note's id and CRDT lineage, so the plugin sees the same
note come back, not a rival one.
"""

import time
import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import wait_for_binary_delivery
from helpers.vault import wait_for_content, wait_for_file, wait_for_file_gone

# Minimal valid PNG: 1x1 red pixel (same bytes as test_33).
TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)

# Long enough for a late duplicate or conflict copy to land after the restore.
SETTLE_SECONDS = 5


def _structured(response: dict) -> dict:
    result = response["result"]
    assert not result.get("isError"), result["content"][0]["text"]
    return result["structuredContent"]


def _files_under(vault, folder: str) -> list[str]:
    root = vault / folder
    return sorted(str(p.relative_to(vault)) for p in root.rglob("*") if p.is_file())


@pytest.mark.asyncio
async def test_mcp_delete_folder_then_restore_reappears(vault_b, cdp_b, api_sync):
    folder = f"E2E/Restore106-{uuid.uuid4().hex[:8]}"
    notes = {
        f"{folder}/alpha.md": "# Alpha\nalpha body 106",
        f"{folder}/beta.md": "# Beta\nbeta body 106",
        f"{folder}/Sub/gamma.md": "# Gamma\ngamma body 106",
    }
    att = f"{folder}/img.png"

    await cdp_b.wait_for_stream_connected(timeout=DELIVERY_TIMEOUT)

    for path, content in notes.items():
        api_sync.create_note(path, content)
    assert api_sync.upload_attachment(att, TINY_PNG, "image/png") in (200, 201)

    for path, content in notes.items():
        wait_for_content(vault_b, path, content.splitlines()[1])
    assert wait_for_binary_delivery(vault_b, att, api_sync) == TINY_PNG

    resp, status = api_sync.mcp_call("delete_folder", {"folder": folder, "recursive": True})
    assert status == 200
    deleted = _structured(resp)
    assert deleted["notes"] == 3 and deleted["attachments"] == 1, deleted
    op_id = deleted["delete_op_id"]
    assert op_id and deleted["restorable_until"]

    for path in [*notes, att]:
        wait_for_file_gone(vault_b, path)

    resp, status = api_sync.mcp_call("restore_deleted", {"op_id": op_id})
    assert status == 200
    restored = _structured(resp)
    assert restored["notes"] == 3, restored
    assert restored["attachments"] == 1, restored
    assert restored["skipped"] == [], restored

    for path, content in notes.items():
        wait_for_file(vault_b, path)
        wait_for_content(vault_b, path, content.splitlines()[1])
    assert wait_for_binary_delivery(vault_b, att, api_sync) == TINY_PNG

    time.sleep(SETTLE_SECONDS)

    # Exactly the original files: no "(conflict ...)" copy, no duplicate.
    assert _files_under(vault_b, folder) == sorted([*notes, att])
    for path, content in notes.items():
        assert (vault_b / path).read_text(encoding="utf-8").count(content.splitlines()[1]) == 1

    # A second restore brings back nothing more (idempotent).
    resp, _ = api_sync.mcp_call("restore_deleted", {"op_id": op_id})
    again = _structured(resp)
    assert again["notes"] == 0 and again["attachments"] == 0, again
