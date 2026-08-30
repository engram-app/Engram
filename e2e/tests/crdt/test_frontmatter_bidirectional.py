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
import time

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
# Long enough for a post-unbind flush to land, short enough that several of
# these nest inside pytest.ini's 180s cap. A full CRDT_TIMEOUT here would blow
# the per-test budget on its own and report as a SIGALRM traceback rather than
# the assertion, which is the wrong-diagnosis outcome helpers/latency.py exists
# to prevent.
SETTLE_SECONDS = 15


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


async def _close_all_in_obsidian(cdp) -> None:
    """Detach every markdown leaf — the user's "close the file".

    This is the transition that releases the live binding. `detach()` is what
    Obsidian's own close button calls, so it fires the same teardown (and the
    same final save) the reported repro goes through."""
    left = await cdp.evaluate(
        """
        (async () => {
          app.workspace.getLeavesOfType("markdown").forEach((l) => l.detach());
          return app.workspace.getLeavesOfType("markdown").length;
        })()
        """,
        await_promise=True,
    )
    assert left == 0, f"markdown leaves still open after detach: {left!r}"


async def _type_into_open_editor(cdp, path: str, text: str) -> None:
    """Set the OPEN editor's buffer, which is what typing produces.

    Deliberately not `write_note`: a disk write goes down `routeModify`, the
    path that already works. The reported bug needs the edit to originate in
    the bound CodeMirror buffer. `editor.setValue` drives the same CM6
    transaction pipeline a keystroke does, so `classifyEditSpan` sees it.

    The frontmatter is part of the editor document even though the properties
    widget renders it as a decoration, so the fenced block belongs in `text`."""
    got = await cdp.evaluate(
        """
        (async () => {
          const ed = app.workspace.activeEditor;
          if (!ed || ed.file?.path !== %r) return "not-active";
          ed.editor.setValue(%r);
          await app.workspace.activeEditor.save?.();
          return ed.editor.getValue();
        })()
        """
        % (path, text),
        await_promise=True,
    )
    assert got == text, f"editor buffer did not take the edit for {path}: {got!r}"


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
    await expect(web.property_value_locator("status")).to_have_value(
        "draft", timeout=MS
    )

    # Change the value from Obsidian while the note is not open there.
    write_note(vault_a, path, "---\nstatus: published\n---\n\nbody v1\n")
    await expect(web.property_value_locator("status")).to_have_value(
        "published", timeout=MS
    )


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
    await expect(web.property_value_locator("status")).to_have_value(
        "draft", timeout=MS
    )

    write_note(vault_a, path, "---\nstatus: published\n---\n\nbody v1\n")
    await expect(web.property_value_locator("status")).to_have_value(
        "published", timeout=MS
    )


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
    #
    # The BODY changes in the same write, and is what we synchronise on. An
    # earlier version of this test waited for a body string it had just written
    # itself -- `wait_for_content` returns on its first poll if the substring is
    # already there, so it read the file back microseconds later, before any
    # ingest could have started, and passed with the defect fully present.
    # Waiting for a body marker to come back FROM THE SERVER is what proves the
    # write was actually processed before the keys are judged.
    write_note(
        vault_a,
        path,
        "---\nkeep: me\nalso: here\nbad: [unclosed\n---\n\nbody v2 unparseable\n",
    )
    await expect(web.editor_locator()).to_contain_text(
        "body v2 unparseable", timeout=MS
    )

    # The server has the new content, so the frontmatter it holds is the
    # frontmatter this write produced. The good keys must have survived it --
    # asserted on the WEB APP, because a client-side wipe propagates and takes
    # the rows away here too.
    await expect(web.property_value_locator("keep")).to_have_value("me", timeout=MS)
    await expect(web.property_value_locator("also")).to_have_value("here", timeout=MS)

    # And on disk, where the loss becomes permanent.
    final = read_note(vault_a, path)
    assert "keep:" in final and "also:" in final, (
        f"unparseable YAML deleted the good frontmatter keys; file is now:\n{final!r}"
    )


@pytest.mark.asyncio
async def test_typed_frontmatter_survives_close_and_reopen(
    vault_a, cdp_a, api_sync, web, sync_vault_id
):
    """[5] Reported 2026-08-29, still failing on 1.24.4-pr.482.g206c5f8.

    The distinguishing shape of this one: the frontmatter DOES reach the web
    app and stays there, so the server-side Y.Doc holds it. Only the local file
    loses it, and only across a close/reopen. That rules out ingest (tests 1-3
    prove the doc receives the keys) and points at the doc -> disk projection
    that runs when the live binding is released.

    Every earlier test writes frontmatter with `write_note`. That is the disk
    path, which was never the broken one. This test originates the edit in the
    bound editor buffer, which is what the user actually does, and is the only
    way to put the binding teardown on the critical path.
    """
    path = "E2E/Crdt/FmCloseReopen.md"
    write_note(vault_a, path, "---\nkeep: me\n---\n\nbody v1\n")
    note_id = _note_id(api_sync, path)
    await _open_in_obsidian(cdp_a, path)

    await web.open_note(note_id, sync_vault_id)
    await expect(web.property_value_locator("keep")).to_have_value("me", timeout=MS)

    # Type a second key into the OPEN note.
    await _type_into_open_editor(
        cdp_a, path, "---\nkeep: me\nstatus: published\n---\n\nbody v1\n"
    )

    # It reaches the web app. The user confirms this half works, and asserting
    # it here is what makes the failure below unambiguous: the doc HAS the key
    # at the moment the file is closed.
    await expect(web.property_value_locator("status")).to_have_value(
        "published", timeout=MS
    )

    # Assert while CLOSED. This is the reported state, and it is the strict one:
    # reopening first runs attach() -> enroll -> room rejoin, and any update
    # delivered on that rejoin flushes the FULL projection back to disk, which
    # would repair the file inside the window meant to catch the damage.
    #
    # Poll rather than read once: the loss lands on a flush that follows the
    # unbind, so a single read can pass before the damage.
    deadline = time.monotonic() + SETTLE_SECONDS
    while time.monotonic() < deadline:
        disk = read_note(vault_a, path)
        assert "keep:" in disk and "status:" in disk, (
            "frontmatter vanished from disk after the note was closed; "
            f"file is now:\n{disk!r}"
        )
        time.sleep(0.5)

    # Reopening must not resurrect the problem either, and the server should
    # still agree -- so this was never a delete the user made.
    await _open_in_obsidian(cdp_a, path)
    final = read_note(vault_a, path)
    assert "keep:" in final and "status:" in final, (
        f"frontmatter vanished on reopen; file is now:\n{final!r}"
    )
    await expect(web.property_value_locator("status")).to_have_value(
        "published", timeout=MS
    )
