"""Test 43: Deeply nested folder paths (4+ levels) sync correctly.

Obsidian allows arbitrary nesting. Verifies that deep paths like
E2E/A/B/C/D/Note.md push and reach B live, without path truncation.
"""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import write_note


@pytest.mark.asyncio
async def test_deep_folder_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """4-level deep note syncs A→B live with full path preserved."""
    path = "E2E/Level1/Level2/Level3/Level4/DeepNote43.md"

    write_note(vault_a, path, "# Deep Note\nFour levels of nesting.")
    api_sync.wait_for_note(path)

    # Verify server stored full path
    server_note = api_sync.get_note(path)
    assert server_note["path"] == path, "Server should preserve full nested path"
    assert server_note.get("folder") == "E2E/Level1/Level2/Level3/Level4", \
        f"Folder should be the parent, got: {server_note.get('folder')}"

    # B receives it live — no manual pull
    b_content = wait_for_delivery(vault_b, path, api_sync)
    assert "Deep Note" in b_content


@pytest.mark.asyncio
async def test_deep_folder_multiple_notes(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Multiple notes at different depths all sync correctly, live."""
    paths = {
        "E2E/Depth43/A.md": "# Level 1",
        "E2E/Depth43/Sub/B.md": "# Level 2",
        "E2E/Depth43/Sub/Deep/C.md": "# Level 3",
        "E2E/Depth43/Sub/Deep/Deeper/D.md": "# Level 4",
    }

    for path, content in paths.items():
        write_note(vault_a, path, content)

    # Wait for all on server
    for path in paths:
        api_sync.wait_for_note(path)

    # All should reach B's vault live — no manual pull. A 4-note burst
    # shares one delivery window and intermittently hits the received=yes
    # materialized=no stall tracked in Engram-obsidian#189; the shared
    # delivery budget covers it and records the actual latency.
    for path, content_prefix in paths.items():
        b_content = wait_for_delivery(vault_b, path, api_sync)
        assert content_prefix.lstrip("# ").split()[0] in b_content, \
            f"B should have {path} with correct content"

    # Verify folder listing includes nested folders
    folders = api_sync.get_folders()
    folder_names = [f["name"] if isinstance(f, dict) else f for f in folders]
    assert any("Depth43/Sub/Deep" in str(f) for f in folder_names), \
        f"Nested folder should appear in folder list: {folder_names[:20]}"
