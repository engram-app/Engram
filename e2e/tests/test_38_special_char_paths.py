"""Test 38: Notes with special characters in filenames sync correctly.

Tests unicode, spaces, parentheses, and emoji in file paths — all common
patterns in real Obsidian vaults. B receives each live, no manual pull.
"""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import write_note


@pytest.mark.asyncio
async def test_spaces_in_path(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with spaces in name syncs A→B live."""
    path = "E2E/My Notes (2026).md"
    content = "# Spaced Path\nContent with spaces in filename."

    write_note(vault_a, path, content)
    api_sync.wait_for_note(path, timeout=10)

    received = wait_for_delivery(vault_b, path, api_sync, timeout=30)
    assert content in received


@pytest.mark.asyncio
async def test_unicode_in_path(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with unicode characters syncs A→B live."""
    path = "E2E/Café Résumé.md"
    content = "# Café Notes\nAccented characters in filename."

    write_note(vault_a, path, content)
    api_sync.wait_for_note(path, timeout=10)

    received = wait_for_delivery(vault_b, path, api_sync, timeout=30)
    assert content in received


@pytest.mark.asyncio
async def test_emoji_in_path(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with emoji in name syncs A→B live (common Obsidian pattern)."""
    path = "E2E/📝 Daily Log.md"
    content = "# Daily Log\nEmoji filename test."

    write_note(vault_a, path, content)
    api_sync.wait_for_note(path, timeout=10)

    received = wait_for_delivery(vault_b, path, api_sync, timeout=30)
    assert content in received


@pytest.mark.asyncio
async def test_special_chars_combined(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """File with mixed special characters syncs A→B live."""
    path = "E2E/Project [v2.0] — Final (Draft).md"
    content = "# Mixed Special Chars\nBrackets, em-dash, parens."

    write_note(vault_a, path, content)
    api_sync.wait_for_note(path, timeout=10)

    received = wait_for_delivery(vault_b, path, api_sync, timeout=30)
    assert content in received
