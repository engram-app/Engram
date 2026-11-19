"""Test 106: MCP delete_folder, then restore_deleted, brings the files back.

Safer delete (#609). An agent deletes a folder through MCP; the connected
Obsidian trashes the files live. One restore_deleted call with the returned
delete_op_id must bring every note and the attachment back on that same
device, with their content, and with no conflict copy or duplicate: the
restore keeps each note's id and CRDT lineage, so the plugin sees the same
note come back, not a rival one.
"""

import datetime
import time
import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import receiver_device_id, wait_for_binary_delivery
from helpers.vault import TINY_PNG, files_under, wait_for_content, wait_for_file, wait_for_file_gone


# Long enough for a late duplicate or conflict copy to land after the restore.
SETTLE_SECONDS = 5


def _dump_receiver_logs(api_sync, vault, since: str) -> None:
    """Print the receiver's own client log since the delete, for a failure.

    Paths are redacted to n1, n2... labels in client logs, so this is the
    whole window for that one device, not a path filter.
    """
    device = receiver_device_id(vault)
    for entry in api_sync.list_logs(limit=1000, since=since, device_id=device or ""):
        print(f"[B log] {entry.get('timestamp')} {entry.get('level')} "
              f"{entry.get('category')}: {entry.get('message')}")


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

    since = datetime.datetime.now(datetime.timezone.utc).isoformat()
    deleted = api_sync.mcp_tool("delete_folder", {"folder": folder, "recursive": True})[
        "structuredContent"
    ]
    assert deleted["notes"] == 3 and deleted["attachments"] == 1, deleted
    op_id = deleted["delete_op_id"]
    assert op_id and deleted["restorable_until"]

    for path in [*notes, att]:
        wait_for_file_gone(vault_b, path)

    restored = api_sync.mcp_tool("restore_deleted", {"op_id": op_id})["structuredContent"]
    assert restored["notes"] == 3, restored
    assert restored["attachments"] == 1, restored
    assert restored["skipped"] == [], restored

    try:
        for path, content in notes.items():
            wait_for_file(vault_b, path)
            wait_for_content(vault_b, path, content.splitlines()[1])
        assert wait_for_binary_delivery(vault_b, att, api_sync) == TINY_PNG

        time.sleep(SETTLE_SECONDS)

        # Exactly the original files: no "(conflict ...)" copy, no duplicate.
        assert files_under(vault_b, folder) == {*notes, att}
    except (AssertionError, TimeoutError):
        print(f"[B files] {sorted(files_under(vault_b, folder))}")
        _dump_receiver_logs(api_sync, vault_b, since)
        raise
    for path, content in notes.items():
        assert (vault_b / path).read_text(encoding="utf-8").count(content.splitlines()[1]) == 1

    # A second restore brings back nothing more (idempotent).
    again = api_sync.mcp_tool("restore_deleted", {"op_id": op_id})["structuredContent"]
    assert again["notes"] == 0 and again["attachments"] == 0, again
