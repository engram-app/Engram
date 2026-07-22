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
from helpers.latency import DELIVERY_TIMEOUT

logger = logging.getLogger(__name__)

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound; latency is recorded, not asserted


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


@pytest.mark.asyncio
async def test_web_edit_reaches_obsidian_that_missed_room_open(
    web, vault_b, cdp_b, api_sync, sync_vault_id
):
    """Regression guard: a live web edit reaches an Obsidian instance that was
    OFF the channel when the web opened the note's room.

    Under the vault-channel model B no longer relies on the old checkpoint-
    ROOM-OPEN announce (#940). B is disconnected when the web opens the note, so
    it misses any room-open announce and never observes the room. When B
    reconnects, its reconnect catch-up runs pull() → coldReceive(), which diffs
    the server head-index against B's persisted per-note crdtHead and pulls +
    applies the web edit's Yjs delta — converging B's disk without B ever
    opening the note's room.

    So this FAILS if the cold-receive reconnect path is broken (the edit never
    reaches B) and PASSES with it.
    """
    path = "E2E/Crdt/WebMissedOpen.md"

    api_sync.create_note(path, "# Missed Open\nbase content.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base content", timeout=CRDT_TIMEOUT)
    note_id = _note_id(api_sync, path)

    # B goes OFF the channel, THEN the web opens the room — so B misses the
    # room-open announce entirely.
    await cdp_b.disconnect_stream()
    await web.open_note(note_id, sync_vault_id)

    # B comes back ON the channel. It does NOT re-observe this closed note's room
    # (reEnrollOpenCrdtNotes covers only OPEN notes) and it already missed the
    # room-open announce. The only remaining path to B is the checkpoint announce.
    await cdp_b.reconnect_stream()

    await web.append("\nEDIT-AFTER-MISSED-OPEN\n")
    t_edit = time.monotonic()
    final = wait_for_content(vault_b, path, "EDIT-AFTER-MISSED-OPEN", timeout=CRDT_TIMEOUT)
    logger.info("missed-open web-edit -> B-disk latency: %.1fs", time.monotonic() - t_edit)
    assert "base content" in final, f"base content lost on B: {final!r}"
