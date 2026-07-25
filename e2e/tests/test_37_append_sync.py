"""Test 37: Append-only sync — POST /notes/append adds content, B receives it live.

Verifies that server-side append modifies the note and the appended
content propagates to B over live sync, with no manual pull.
"""

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_content, write_note


@pytest.mark.asyncio
async def test_append_sync(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Append via API grows the note, B receives cumulative content live."""
    path = "E2E/AppendSync37.md"

    # A creates the base note
    write_note(vault_a, path, "# Append Test\nOriginal content.")
    api_sync.wait_for_note(path)

    # B receives the base note live (first delivery — file doesn't exist yet)
    wait_for_delivery(vault_b, path, api_sync)

    # Append via API
    status = api_sync.append_note(path, "\nAppended line 1.")
    assert status == 200, f"First append should succeed, got {status}"

    # Verify server has appended content
    api_sync.wait_for_note_content(path, "Appended line 1")

    # B receives the appended content live. B's file already exists (from the
    # base note above) so the delivery oracle's non-empty guard can't detect
    # this specific update; wait_for_content polls for the new marker instead
    # — still a pure vault-disk poll, no pull involved.
    b_content = wait_for_content(vault_b, path, "Appended line 1")
    assert "Original content" in b_content, "Original content should be preserved"

    # Append again
    status = api_sync.append_note(path, "\nAppended line 2.")
    assert status == 200, f"Second append should succeed, got {status}"
    api_sync.wait_for_note_content(path, "Appended line 2")

    # B receives the second append live — cumulative
    b_content = wait_for_content(vault_b, path, "Appended line 2")
    assert "Appended line 1" in b_content, "First append should still be present"
    assert "Appended line 2" in b_content, "Second append should be present"
