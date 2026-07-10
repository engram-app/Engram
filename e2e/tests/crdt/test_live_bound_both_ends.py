"""Reproduces p0 engram-app/Engram-obsidian#224: a note LIVE-BOUND in Obsidian's
editor does not converge on a remote edit without a hard restart.

The existing CRDT live tests open the note on only ONE end:
  - test_obsidian_to_web_live: web editor open, Obsidian writes via file.
  - test_web_to_obsidian_live: web editor open, Obsidian receives on disk (its
    editor is NOT open, so its Y.Doc is not live-bound).

The p0 failure only appears when the RECEIVER's editor is OPEN (live-bound):
the catch-up re-handshake can't merge the server's canonical state into an
already-bound Y.Doc, so it diverges, the bounded retry exhausts, and the edit
never lands until a full restart. This test opens the note in Obsidian's
editor BEFORE the remote edit, which is the missing coverage.

Marked xfail(strict=False): the bug is intermittent ("works after restart,
degrades otherwise"), so this documents it without breaking CI. Flip to a hard
assertion when #224 is fixed.
"""

from __future__ import annotations

import os

import pytest

from helpers.vault import wait_for_content

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = 30


def _note_id(api_sync, path: str) -> str:
    note = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = note.get("note", note) if isinstance(note, dict) else {}
    nid = inner.get("id") or inner.get("note_id") or inner.get("uuid")
    assert nid, f"no note id in GET /notes/{path}: {note}"
    return str(nid)


@pytest.mark.asyncio
@pytest.mark.xfail(
    reason="p0 engram-app/Engram-obsidian#224: live-bound receiver does not "
    "converge on a remote edit without a restart",
    strict=False,
)
async def test_remote_edit_converges_while_note_is_live_bound_in_obsidian(
    web, vault_b, cdp_b, api_sync, sync_vault_id
):
    path = "E2E/Crdt/BothLiveBound224.md"

    # Establish the note on B's disk (setup only; trigger_full_sync here is fine
    # because the ASSERTION below uses no full-sync).
    api_sync.create_note(path, "# Both Live Bound\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)

    # THE trigger: open the note in Obsidian's editor so its Y.Doc is LIVE-BOUND
    # when the remote edit arrives (the condition the other tests never set up).
    opened = await cdp_b.evaluate(
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
    assert opened == path, f"failed to live-bind note in Obsidian editor: {opened!r}"

    # Edit from the web SPA over the CRDT channel.
    note_id = _note_id(api_sync, path)
    await web.open_note(note_id, sync_vault_id)
    await web.append("\nEDIT-WHILE-B-LIVE-BOUND\n")

    # B must converge on disk with NO trigger_full_sync. Under #224 this times
    # out (live-bound re-handshake never merges) until a hard restart.
    final = wait_for_content(vault_b, path, "EDIT-WHILE-B-LIVE-BOUND", timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base content lost on B: {final!r}"
