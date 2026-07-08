"""Test 49: Cross-auth bidirectional sync + rapid edit edge cases.

Verifies that OAuth and API key authenticated clients can coexist on the same
channel topic and sync bidirectionally. Also tests rapid successive edits to
catch debounce/dedup edge cases.

Requires E2E_CLERK_SECRET_KEY env var.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
import uuid

import pytest

from helpers.oauth import (
    provision_oauth_for_existing_user,
    swap_to_oauth,
    restore_auth,
    wait_for_stream,
)
from helpers.vault import read_note, wait_for_content, wait_for_file, write_note

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping cross-auth sync tests",
)

# ponytail: 30s is a load-tuned CI budget, not a latency proof — 5 rapid
# edits must settle end-to-end on a shared loaded runner (was 10, flaked).
RT_TIMEOUT = 30


def _log_latency(label: str, t0: float) -> float:
    elapsed = time.monotonic() - t0
    logger.info("LATENCY [%s]: %.3fs", label, elapsed)
    return elapsed


# ---------------------------------------------------------------------------
# Tests: Bidirectional sync across auth methods
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_apikey_push_oauth_receives(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_user, clerk_client, _oauth_ws_warm
):
    """API key client (B) pushes a note → OAuth client (A) receives via WebSocket.

    A is swapped to OAuth, B stays on API key. B creates a note via file write,
    pushes it, and A should receive the broadcast.
    """
    tokens = await provision_oauth_for_existing_user(
        clerk_client, API_URL, sync_user[1], label="cross",
        api_key=sync_user[2],
    )
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        # B (API key) creates a note. Unique path per run: these tests share the
        # session-scoped sync_user, so a fixed path left over from a failed
        # attempt would make the rerun's identical re-push hit the server's
        # hash-equal broadcast-skip (idempotent no-op) and never deliver — a
        # deterministic rerun failure. Unique paths keep every attempt a fresh,
        # broadcasting insert (same rerun-safety approach as test_58/test_59).
        path = f"E2E/CrossAuthApikeyToOauth-{uuid.uuid4().hex[:12]}.md"
        content = "# API Key → OAuth\nPushed by API key client, received by OAuth"
        write_note(vault_b, path, content)

        # Wait for B to push to server
        api_sync.wait_for_note(path, timeout=10)

        # A (OAuth) should receive via WebSocket
        t0 = time.monotonic()
        a_content = wait_for_file(vault_a, path, timeout=RT_TIMEOUT)
        _log_latency("apikey_push_oauth_receives", t0)

        assert "received by OAuth" in a_content

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)


@pytest.mark.asyncio
async def test_oauth_push_apikey_receives(
    vault_a, vault_b, cdp_a, cdp_b, api_sync, sync_user, clerk_client, _oauth_ws_warm
):
    """OAuth client (A) pushes a note → API key client (B) receives via WebSocket.

    A is swapped to OAuth. A writes a file, syncs, B should get it.
    """
    tokens = await provision_oauth_for_existing_user(
        clerk_client, API_URL, sync_user[1], label="cross",
        api_key=sync_user[2],
    )
    original_settings = None

    try:
        original_settings = await swap_to_oauth(cdp_a, tokens)
        await wait_for_stream(cdp_a)

        assert await cdp_a.check_stream_connected(), "A (OAuth) not connected"
        assert await cdp_b.check_stream_connected(), "B (API key) not connected"

        # A (OAuth) creates a note and syncs. Unique path per run for rerun-safety
        # (see test_apikey_push_oauth_receives).
        path = f"E2E/CrossAuthOauthToApikey-{uuid.uuid4().hex[:12]}.md"
        content = "# OAuth → API Key\nPushed by OAuth client, received by API key"
        write_note(vault_a, path, content)

        result = await cdp_a.trigger_full_sync()
        logger.info("OAuth push result: %s", result)

        # B (API key) should receive via WebSocket
        t0 = time.monotonic()
        b_content = wait_for_file(vault_b, path, timeout=RT_TIMEOUT)
        _log_latency("oauth_push_apikey_receives", t0)

        assert "received by API key" in b_content

    finally:
        if original_settings:
            await restore_auth(cdp_a, original_settings)
            await wait_for_stream(cdp_a)


# ---------------------------------------------------------------------------
# Tests: Rapid successive edits
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
async def test_rapid_api_edits_final_content_arrives(vault_b, cdp_b, api_sync):
    """Multiple rapid API edits to same note → final content arrives at client.

    Tests that debounce/dedup logic doesn't drop the final update.
    """
    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    # Unique path per run for rerun-safety (shared sync_user; see
    # test_apikey_push_oauth_receives). The final "Version 5 of 5" would hash-equal
    # a leftover from a prior attempt and never re-broadcast.
    path = f"E2E/RapidEdits-{uuid.uuid4().hex[:12]}.md"

    # Fire 5 rapid edits (no sleep between them)
    for i in range(1, 6):
        api_sync.create_note(path, f"# Rapid Edit\nVersion {i} of 5")

    # Final content should arrive
    t0 = time.monotonic()
    wait_for_content(vault_b, path, "Version 5 of 5", timeout=RT_TIMEOUT)
    _log_latency("rapid_edits_final", t0)

    final = read_note(vault_b, path)
    assert "Version 5 of 5" in final, f"Expected final version, got: {final[:200]}"


@pytest.mark.asyncio
async def test_rapid_api_edits_content_not_stale(vault_b, cdp_b, api_sync):
    """After rapid edits settle, content should be the LATEST version, not an earlier one.

    Stronger assertion: verifies no stale intermediate version persists after
    the dust settles. Waits extra time to ensure no late broadcast overwrites
    the final content with an earlier version.
    """
    connected = await cdp_b.check_stream_connected()
    assert connected, "B's WebSocket channel is not connected"

    # Unique path per run for rerun-safety (shared sync_user; see
    # test_apikey_push_oauth_receives).
    path = f"E2E/RapidEditsStale-{uuid.uuid4().hex[:12]}.md"

    # Rapid-fire edits
    for i in range(1, 8):
        api_sync.create_note(path, f"# Stale Check\nIteration {i}")

    # Wait for final version to land
    wait_for_content(vault_b, path, "Iteration 7", timeout=RT_TIMEOUT)

    # Wait extra to ensure no stale version overwrites the final one.
    # 1.5s is 3x the plugin's 500ms debounce — enough for any in-flight writes to settle.
    await asyncio.sleep(1.5)

    final = read_note(vault_b, path)
    assert "Iteration 7" in final, (
        f"Content should be latest iteration (7), got: {final[:200]}"
    )
    # Verify the file contains ONLY the final iteration's content line
    # (earlier iterations should have been overwritten, not appended)
    assert final.count("Iteration") == 1, (
        f"Expected exactly one 'Iteration' line (the final one), "
        f"but found {final.count('Iteration')}: {final[:300]}"
    )
