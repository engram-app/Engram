"""CRDT file-level sync e2e (spec §12a).

These tests exercise behaviours that are UNIQUE to the CRDT sync path and the
regressions that broke it. They run only when the harness opted the plugin into
CRDT (``E2E_ENABLE_CRDT=true``) against a backend that advertises the ``crdt:``
topic (``CRDT_ENABLED=true``); otherwise they skip.

CRDT-aware assertions: unlike the legacy REST path, a CRDT note is
eventually-consistent. The body is delivered device->device over the
y-protocols handshake and only flushed to ``notes.content`` on the debounced
checkpoint (~5s). So these tests poll the *vault file on disk* (the device-side
source of truth) and the REST content with generous timeouts — never an
immediate read-after-write.
"""

from __future__ import annotations

import os

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import delete_note, wait_for_content, wait_for_file_gone, write_note

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

# CRDT delivery = server checkpoint debounce (~5s) + handshake; be generous.
CRDT_TIMEOUT = 30


async def _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, body, marker):
    """Create `path` on A and wait until B has it on disk live — a shared CRDT base.

    No pull backstop: this is the first time `path` exists on B, so the
    delivery oracle's non-empty guard correctly signals arrival.
    """
    write_note(vault_a, path, body)
    api_sync.wait_for_note_content(path, marker, timeout=CRDT_TIMEOUT)
    content = wait_for_delivery(vault_b, path, api_sync, timeout=CRDT_TIMEOUT)
    assert marker in content, f"B never received the shared base for {path}"


@pytest.mark.asyncio
async def test_discovery_creates_file_on_b(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A creates a note B has never had -> the file is CREATED on B's disk.

    Regression: flushFromCrdt returned early when the file didn't exist, so a
    discovered note's body sat in B's Yjs doc but was never written to disk and
    the note stayed permanently invisible on B.
    """
    path = "E2E/Crdt/Discovery.md"
    write_note(vault_a, path, "# Discovery\nbody authored on device A")
    api_sync.wait_for_note_content(path, "device A", timeout=CRDT_TIMEOUT)

    content = wait_for_delivery(vault_b, path, api_sync, timeout=CRDT_TIMEOUT)
    assert "body authored on device A" in content


@pytest.mark.asyncio
async def test_concurrent_edits_both_survive(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A and B independently edit the same note; BOTH edits survive on BOTH
    devices after convergence. This is the defining CRDT property — legacy
    last-write-wins would drop one side.
    """
    path = "E2E/Crdt/Merge.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "shared base\n", "shared base")

    # Independent edits at different positions, applied close together so neither
    # device has seen the other's change yet (true concurrency).
    write_note(vault_a, path, "shared base\nFROM_A\n")
    write_note(vault_b, path, "shared base\nFROM_B\n")

    # Both sides converge live over the y-protocols handshake — no pull
    # backstop. Both files already exist (from the shared base above), so
    # the content-aware poll (not the oracle's non-empty guard) proves the
    # other side's edit actually arrived.
    a_final = wait_for_content(vault_a, path, "FROM_B", timeout=CRDT_TIMEOUT)
    b_final = wait_for_content(vault_b, path, "FROM_A", timeout=CRDT_TIMEOUT)
    assert "FROM_A" in a_final and "FROM_B" in a_final, f"A lost an edit: {a_final!r}"
    assert "FROM_A" in b_final and "FROM_B" in b_final, f"B lost an edit: {b_final!r}"


@pytest.mark.asyncio
async def test_no_conflict_modal_on_divergence(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A divergence that would pop the legacy ConflictModal must merge silently
    under CRDT — no modal is shown (the C1 guard's whole purpose)."""
    path = "E2E/Crdt/NoModal.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "base line\n", "base line")

    write_note(vault_a, path, "base line\nA change\n")
    write_note(vault_b, path, "base line\nB change\n")

    # Wait for the merge to actually converge live before checking for a
    # modal — otherwise "no modal yet" would be a race, not a guarantee.
    wait_for_content(vault_a, path, "B change", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path, "A change", timeout=CRDT_TIMEOUT)

    # No conflict modal open in either app.
    for cdp in (cdp_a, cdp_b):
        modal_count = await cdp.evaluate(
            "document.querySelectorAll('.modal-container .engram-conflict-modal, "
            ".modal .mod-conflict, .engram-conflict-modal').length"
        )
        assert modal_count == 0, "a conflict modal was shown under CRDT"


@pytest.mark.asyncio
async def test_content_reaches_rest_after_checkpoint(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A CRDT-created note's body eventually lands in REST notes.content (via the
    checkpoint flush) — what the web app / initial pull read. Eventually
    consistent, not immediate."""
    path = "E2E/Crdt/RestFlush.md"
    write_note(vault_a, path, "# RestFlush\ncheckpoint should flush this")
    ok = api_sync.wait_for_note_content(path, "checkpoint should flush", timeout=CRDT_TIMEOUT)
    assert ok, "CRDT content never flushed to REST notes.content"


@pytest.mark.asyncio
async def test_delete_propagates(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Deleting a CRDT note on A removes it from B (deletes route around the
    C1 guard, not through the CRDT body path)."""
    path = "E2E/Crdt/DeleteMe.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "delete me\n", "delete me")

    delete_note(vault_a, path)
    wait_for_file_gone(vault_b, path, timeout=CRDT_TIMEOUT)


@pytest.mark.asyncio
async def test_edit_after_discovery_round_trips(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """After B discovers a note, an edit B makes flows back to A — proving the
    discovered note is fully CRDT-managed on B, not a one-shot disk write."""
    path = "E2E/Crdt/RoundTrip.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "origin A\n", "origin A")

    write_note(vault_b, path, "origin A\nappended on B\n")

    a_content = wait_for_content(vault_a, path, "appended on B", timeout=CRDT_TIMEOUT)
    assert "origin A" in a_content and "appended on B" in a_content
