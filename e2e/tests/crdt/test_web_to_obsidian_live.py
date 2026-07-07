"""Cross-device CRDT coverage: a WEB-SPA edit reaches Obsidian (spec §12a).

This is the FIRST test that drives a real browser on the actual web SPA as a
CRDT peer alongside a headless Obsidian instance — the two clients share one
server user + vault. The web SPA's CodeMirror editor is the ONLY client on the
CRDT *checkpoint* path, so an Obsidian<->Obsidian suite structurally cannot
cover it.

What it proves: a note edited in the browser converges to Obsidian's disk over
the CRDT channel, with NO manual full-sync — the real cross-interface path a
user exercises. Delivery is eventually-consistent (handshake + checkpoint
debounce), so we poll the vault file on disk, never a read-after-write.

Note on mechanism: in a clean id-keyed vault the receiver is delivered live via
the channel's room-open announce + observation; the checkpoint's own announce
(engram fix for CRDT-checkpoint-origin writes) is a backstop for the
join-late / not-observing case. This test asserts the end-to-end contract, not
one specific delivery leg.
"""

from __future__ import annotations

import logging
import os
import time

import pytest

from helpers.vault import wait_for_content

logger = logging.getLogger(__name__)

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = 30


def _note_id(api_sync, path: str) -> str:
    """Server note id for `path` (the SPA opens /note/<id>). Shape-robust."""
    note = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = note.get("note", note) if isinstance(note, dict) else {}
    nid = inner.get("id") or inner.get("note_id") or inner.get("uuid")
    assert nid, f"no note id in GET /notes/{path}: {note}"
    return str(nid)


@pytest.mark.asyncio
async def test_web_edit_reaches_obsidian_live(web, vault_b, cdp_b, api_sync, sync_vault_id):
    """An edit made in the browser SPA editor converges to Obsidian's disk —
    without a manual Sync — proving the web<->obsidian CRDT path end to end."""
    path = "E2E/Crdt/WebToObsidian.md"

    # Establish the note and get it onto B's disk, so this is an EDIT to an
    # existing note (not a create).
    api_sync.create_note(path, "# Web To Obsidian\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)

    # The web SPA opens the note and edits it in the CodeMirror editor — a real
    # crdt_msg over the crdt: channel.
    note_id = _note_id(api_sync, path)
    await web.open_note(note_id, sync_vault_id)
    await web.append("\nEDIT-FROM-WEB-crdt\n")
    t_edit = time.monotonic()

    # B converges on disk with NO trigger_full_sync() — the edit must arrive
    # without the user pressing Sync in Obsidian.
    final = wait_for_content(vault_b, path, "EDIT-FROM-WEB-crdt", timeout=CRDT_TIMEOUT)
    logger.info("web-edit -> B-disk latency: %.1fs", time.monotonic() - t_edit)
    assert "base line" in final, f"base content lost on B: {final!r}"
