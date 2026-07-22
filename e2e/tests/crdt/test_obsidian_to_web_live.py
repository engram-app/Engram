"""Cross-device coverage: an OBSIDIAN edit renders LIVE in the web SPA (audit #7).

Counterpart to test_web_to_obsidian_live.py — same `web` fixture, same
CRDT-only placement (the only CI job with local auth `WebSpaPeer` can sign
into; e2e-clerk runs the rest of tests/ under Clerk auth, which this SPA
sign-in helper does not speak).

The SPA's note editor subscribes to the Phoenix CRDT channel and re-seeds its
Y.Doc on any `note_changed` broadcast (frontend/e2e/note-live-update.spec.ts
#277) — an Obsidian plugin push is exactly the "remote client upserts the
open note" case that spec already covers for a REST-originated write. This
proves the same live path for an Obsidian-originated write, with a second
edit landing in the SAME open tab (no `page.goto`/reload) as the assertion
that live delivery, not just initial load, is working.

v1 scope is the read direction only (Obsidian -> web); the write direction
(SPA CodeMirror edit -> Obsidian) is already covered by
test_web_to_obsidian_live.py.
"""

from __future__ import annotations

import os

import pytest
from playwright.async_api import expect

from helpers.vault import write_note
from helpers.latency import DELIVERY_TIMEOUT

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

RT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound; latency is recorded, not asserted


@pytest.mark.asyncio
async def test_obsidian_edit_renders_live_in_spa(vault_a, api_sync, web, sync_vault_id):
    path = "E2E/Crdt/ObsidianToWeb.md"
    write_note(vault_a, path, "# Web Live\nv1 from Obsidian")
    note = api_sync.wait_for_note(path)

    await web.open_note(note["id"], sync_vault_id)
    editor = web.editor_locator()
    await expect(editor).to_contain_text("v1 from Obsidian", timeout=15_000)

    # THE assertion: a fresh Obsidian edit appears in the already-open tab
    # WITHOUT any reload/navigation.
    write_note(vault_a, path, "# Web Live\nv2 live update")
    await expect(editor).to_contain_text("v2 live update", timeout=RT_TIMEOUT * 1_000)
