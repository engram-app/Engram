"""Frontmatter round-trip between Obsidian and the web SPA (P0).

Reported 2026-08-29: with a note open in Obsidian, body edits synced instantly
while frontmatter did not move at all, and closing/reopening the note DELETED
the frontmatter rather than repairing it.

Frontmatter is not stored in the body Y.Text. It lives in four separate shared
types (`frontmatter` values, `frontmatter_order`, `frontmatter_raw`,
`frontmatter_types`), and the three clients implement different subsets:

  SPA     reads AND writes them, observed live (properties widget)
  server  reads them, projects back to plaintext
  plugin  WRITES them only, via the disk-save path. Observes nothing.

So every existing test passes: the whole CRDT suite drives body text, and the
one place frontmatter is asserted (test_100) is a single-device lineage check.
Nothing exercises frontmatter ACROSS two interfaces, which is exactly where the
plugin's missing half lives.

These four are the reproduction. They are expected to fail on the current
build; that is the point of landing them first.

Coverage map, deliberately both directions and both bindings:

  1. obsidian -> web, note CLOSED in Obsidian   (disk-save path, should pass)
  2. obsidian -> web, note OPEN in Obsidian     (live path drops FM keystrokes)
  3. web -> obsidian, note OPEN in Obsidian     (no inbound listener at all)
  4. bad YAML must not delete good keys         (the data-loss path)
"""

from __future__ import annotations

import os

import pytest
from playwright.async_api import expect

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import read_note, wait_for_content, write_note

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = DELIVERY_TIMEOUT
MS = CRDT_TIMEOUT * 1_000


def _note_id(api_sync, path: str) -> str:
    note = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = note.get("note", note) if isinstance(note, dict) else {}
    nid = inner.get("id") or inner.get("note_id") or inner.get("uuid")
    assert nid, f"no note id in GET /notes/{path}: {note}"
    return str(nid)


async def _open_in_obsidian(cdp, path: str) -> None:
    """Live-bind the note in Obsidian's editor (same incantation as
    test_live_bound_both_ends). Binding is what routes edits through the CM
    plugin instead of the disk-save path, and it is the reported trigger."""
    opened = await cdp.evaluate(
        """
        (async () => {
          const f = app.vault.getAbstractFileByPath(%r);
          if (!f) return "no-file";
          await app.workspace.getLeaf(false).openFile(f);
          return app.workspace.activeEditor?.file?.path ?? "no-active";
        })()
        """
        % path,
        await_promise=True,
    )
    assert opened == path, f"failed to live-bind {path} in Obsidian: {opened!r}"


@pytest.mark.asyncio
async def test_obsidian_frontmatter_reaches_web_when_note_is_closed(
    vault_a, api_sync, web, sync_vault_id
):
    """[1] Obsidian -> web with the note CLOSED. The disk-save path
    (`routeModify` -> `seedContentInto`) owns this, so it is the control: if
    this fails, frontmatter sync is broken everywhere and not just live."""
    path = "E2E/Crdt/FmClosed.md"
    write_note(vault_a, path, "---\nstatus: draft\n---\n\nbody v1\n")
    note_id = _note_id(api_sync, path)

    await web.open_note(note_id, sync_vault_id)
    await expect(web.property_value_locator("status")).to_have_value("draft", timeout=MS)

    # Change the value from Obsidian while the note is not open there.
    write_note(vault_a, path, "---\nstatus: published\n---\n\nbody v1\n")
    await expect(web.property_value_locator("status")).to_have_value("published", timeout=MS)


@pytest.mark.asyncio
async def test_obsidian_frontmatter_reaches_web_when_note_is_open(
    vault_a, cdp_a, api_sync, web, sync_vault_id
):
    """[2] Obsidian -> web with the note OPEN in Obsidian.

    `classifyEditSpan` returns "frontmatter" for a keystroke inside the block
    and the live binding drops it, on the premise that another mechanism owns
    frontmatter. Whether the disk-save path still catches it decides if this is
    a latency bug or a loss bug — this test is what tells them apart.
    """
    path = "E2E/Crdt/FmOpen.md"
    write_note(vault_a, path, "---\nstatus: draft\n---\n\nbody v1\n")
    note_id = _note_id(api_sync, path)
    await _open_in_obsidian(cdp_a, path)

    await web.open_note(note_id, sync_vault_id)
    await expect(web.property_value_locator("status")).to_have_value("draft", timeout=MS)

    write_note(vault_a, path, "---\nstatus: published\n---\n\nbody v1\n")
    await expect(web.property_value_locator("status")).to_have_value("published", timeout=MS)


@pytest.mark.asyncio
async def test_web_property_reaches_obsidian_with_note_open(
    vault_b, cdp_b, api_sync, web, sync_vault_id
):
    """[3] web -> obsidian with the note OPEN in Obsidian. The reported bug.

    Nothing in the plugin observes the frontmatter shared types (the live
    binding observes `text` only, at live-binding.ts:374 and :402), and
    `wiring.ts:345` skips the disk flush for a bound path because "a remote
    merge just painted in" — which is true of the body and false of the
    frontmatter. So a property set in the SPA has no route to an open note.
    """
    path = "E2E/Crdt/FmWebToObsidian.md"
    api_sync.create_note(path, "---\nstatus: draft\n---\n\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)

    await _open_in_obsidian(cdp_b, path)

    note_id = _note_id(api_sync, path)
    await web.open_note(note_id, sync_vault_id)
    await web.set_property("status", "published")

    disk = wait_for_content(vault_b, path, "published", timeout=CRDT_TIMEOUT)
    assert "base line" in disk, f"body lost while delivering frontmatter: {disk!r}"


@pytest.mark.asyncio
async def test_unparseable_frontmatter_does_not_delete_existing_keys(
    vault_a, api_sync, web, sync_vault_id
):
    """[4] The data-loss path, and the reason this is a P0 rather than a sync bug.

    `seedContentInto` collapses two different facts into one:

        const parsed = fmBlock === null ? null : parseFrontmatter(fmBlock);
        const order  = parsed ? parsed.order  : [];
        const values = parsed ? parsed.values : {};

    `parsed` is null both when the note HAS NO frontmatter (deleting every key
    is correct) and when it HAS frontmatter that did not parse (deleting every
    key destroys the user's properties). `applyFrontmatterInto` then removes
    every key absent from `values`, the projection emits a body-only note, and
    the flush writes that over the file on every device.

    Half-typed YAML is invalid constantly, so the trigger is ordinary use. The
    server does not behave this way — `parse_for_ingest` keeps the good keys and
    preserves the bad one verbatim in the raws map.
    """
    path = "E2E/Crdt/FmBadYaml.md"
    write_note(vault_a, path, "---\nkeep: me\nalso: here\n---\n\nbody v1\n")
    note_id = _note_id(api_sync, path)

    await web.open_note(note_id, sync_vault_id)
    await expect(web.property_value_locator("keep")).to_have_value("me", timeout=MS)

    # A transiently-unparseable block: an unclosed flow sequence. This is what
    # sits on disk for as long as it takes to type the closing bracket.
    write_note(vault_a, path, "---\nkeep: me\nalso: here\nbad: [unclosed\n---\n\nbody v1\n")

    # The good keys must survive. Asserting on DISK: the projection is what
    # overwrites the file, so this is where the loss becomes permanent.
    wait_for_content(vault_a, path, "body v1", timeout=CRDT_TIMEOUT)
    final = read_note(vault_a, path) or ""
    assert "keep:" in final and "also:" in final, (
        "unparseable YAML deleted the good frontmatter keys; "
        f"file is now:\n{final!r}"
    )
