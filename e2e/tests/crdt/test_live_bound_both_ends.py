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

Hard-gated since plugin #242 (the live-bound REST-converge fix for the
2026-07-14 deaf-note incident). test_deaf_live_bound_note_converges_via_rest_catchup
below stages the previously-intermittent wedge DETERMINISTICALLY: room killed
server-side + handshake budget zeroed, so the old channel-heal path cannot
succeed and only the REST catch-up can converge the note. It fails on
pre-#242 plugins (which faked convergence after 3 re-handshakes) and passes
with the fix.
"""

from __future__ import annotations

import os

import pytest

from helpers.backend_rpc import backend_rpc
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


@pytest.mark.asyncio
async def test_deaf_live_bound_note_converges_via_rest_catchup(
    web, vault_b, cdp_b, api_sync, sync_vault_id
):
    """Deterministic regression stage for the 2026-07-14 deaf-note incident.

    Production wedge: a note open in Obsidian's editor (live-bound) whose CRDT
    room observation silently died. The plugin discards vault fan-out frames
    for live-bound notes (the room "owns" them), its re-handshake could not
    get through, and the old catch-up FAKED convergence after 3 attempts --
    the note went one-way deaf until an Obsidian restart.

    Deterministic stage: kill the note's room out from under B (B's client
    keeps believing it is enrolled -- exactly the prod state) AND zero the
    crdt handshake budget so a STEP1 re-handshake cannot heal the channel
    path. The ONLY way B can converge is the plugin's REST delta catch-up
    (plugin #242). Pre-#242 plugins time out here deterministically.
    """
    path = "E2E/Crdt/DeafLiveBound.md"

    api_sync.create_note(path, "# Deaf Live Bound\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)

    # Live-bind the note in B's editor BEFORE the wedge, so B's Y.Doc owns it.
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

    note_id = _note_id(api_sync, path)
    await web.open_note(note_id, sync_vault_id)

    # Stage the deafness: the room dies (B is silently no longer an observer;
    # the web's own next keystroke recreates it and re-observes only the web),
    # and the handshake budget goes to zero (every STEP1 -> rate_limited), so
    # the channel path cannot self-heal. put_env is node-local; the CI stack
    # is single-node.
    backend_rpc(f'Engram.Notes.CrdtRegistry.terminate_room("{note_id}")')
    # Capture the pre-test override (the CI stack deliberately raises it, #999)
    # so the finally-restore puts back the configured value, not a bare default.
    prior = backend_rpc(
        "IO.puts(inspect(Application.get_env(:engram, :crdt_hs_rate_limit_override)))"
    ).strip()
    backend_rpc("Application.put_env(:engram, :crdt_hs_rate_limit_override, 0)")
    try:
        await web.append("\nEDIT-WHILE-B-DEAF\n")

        # Wait for the server row to materialize the edit (checkpoint debounce)
        # so B's pull sees the diverged content_hash, then run B's sync. The
        # pull IS the path under test: applyChange's live-bound branch must
        # converge via the REST delta, not via the (blocked) re-handshake.
        api_sync.wait_for_note_content(path, "EDIT-WHILE-B-DEAF", timeout=CRDT_TIMEOUT)
        await cdp_b.trigger_full_sync()

        final = wait_for_content(vault_b, path, "EDIT-WHILE-B-DEAF", timeout=CRDT_TIMEOUT)
        assert "base line" in final, f"base content lost on B: {final!r}"
    finally:
        backend_rpc(
            f"Application.put_env(:engram, :crdt_hs_rate_limit_override, {prior})"
        )
