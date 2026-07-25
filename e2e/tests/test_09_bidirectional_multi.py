"""Test 09: A creates 3 files, B creates 3 files → both vaults end up with all 6."""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import list_notes, read_note, write_note


@pytest.mark.asyncio
async def test_bidirectional_multi_file(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides create multiple files; after live sync, both vaults have all of them."""
    a_files = {
        "E2E/Multi/FromA-1.md": "# From A 1\nFirst file from A",
        "E2E/Multi/FromA-2.md": "# From A 2\nSecond file from A",
        "E2E/Multi/FromA-3.md": "# From A 3\nThird file from A",
    }
    b_files = {
        "E2E/Multi/FromB-1.md": "# From B 1\nFirst file from B",
        "E2E/Multi/FromB-2.md": "# From B 2\nSecond file from B",
        "E2E/Multi/FromB-3.md": "# From B 3\nThird file from B",
    }

    # A creates its files
    for path, content in a_files.items():
        write_note(vault_a, path, content)

    # B creates its files
    for path, content in b_files.items():
        write_note(vault_b, path, content)

    # Wait for all 6 files to land on server
    for path in list(a_files) + list(b_files):
        api_sync.wait_for_note(path)

    # A receives B's files live, B receives A's files live — no manual pull.
    for path in b_files:
        wait_for_delivery(vault_a, path, api_sync)
    for path in a_files:
        wait_for_delivery(vault_b, path, api_sync)

    # Verify A has all 6 files
    for path in list(a_files) + list(b_files):
        content = read_note(vault_a, path)
        assert content, f"A missing {path}"

    # Verify B has all 6 files
    for path in list(a_files) + list(b_files):
        content = read_note(vault_b, path)
        assert content, f"B missing {path}"

    # Verify content integrity
    for path, expected in {**a_files, **b_files}.items():
        a_content = read_note(vault_a, path)
        b_content = read_note(vault_b, path)
        heading = expected.split("\n")[0]
        assert heading in a_content, f"A's {path} missing heading"
        assert heading in b_content, f"B's {path} missing heading"
