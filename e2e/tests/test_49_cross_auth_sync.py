"""Test 49: Cross-auth bidirectional sync + rapid edit edge cases.

Verifies that OAuth and API key authenticated clients can coexist on the same
channel topic and sync bidirectionally. Also tests rapid successive edits to
catch debounce/dedup edge cases.

Requires E2E_CLERK_SECRET_KEY env var.
"""

from __future__ import annotations

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
from helpers.latency import DELIVERY_TIMEOUT
from helpers.quiescence import await_quiescent

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — skipping cross-auth sync tests",
)

# ponytail: 30s is a load-tuned CI budget, not a latency proof — 5 rapid
# edits must settle end-to-end on a shared loaded runner (was 10, flaked).
RT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound, not a latency assert


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
        clerk_client,
        API_URL,
        sync_user[1],
        label="cross",
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
        api_sync.wait_for_note(path)

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
        clerk_client,
        API_URL,
        sync_user[1],
        label="cross",
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
@pytest.mark.parametrize("rep", range(10))  # PROOF ONLY, do not merge
async def test_rapid_api_edits_final_content_arrives(
    vault_b, cdp_a, cdp_b, api_sync, rep
):
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
    # Earlier versions must have been overwritten, not appended.
    assert final.count("Version") == 1, (
        f"Expected only the final version line: {final[:300]}"
    )

    # The device check alone misses the worse half of #2271: a receiver that
    # wrote a stale version, read its own write back as a user edit and
    # PUSHED it left the server on "Version 4 of 5" or "Version 51 of 5"
    # while B briefly showed v5. Wait until both receivers owe nothing
    # outbound (no fullSync kick: a pull could mask the revert), then the
    # server must still hold exactly the last save.
    for cdp in (cdp_a, cdp_b):
        await await_quiescent(cdp, api_sync, kick=False, caught_up=False)
    server = api_sync.get_note(path)
    assert server is not None, f"{path} vanished from the server"
    assert server["content"] == "# Rapid Edit\nVersion 5 of 5", (
        f"Server lost the last save (a receiver pushed stale text back): "
        f"{server['content']!r}"
    )
    assert read_note(vault_b, path) == server["content"], (
        f"B drifted after settling: {read_note(vault_b, path)!r}"
    )
