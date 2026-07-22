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

D3 gate (single-path CRDT): the paired plugin PR deletes the REST backstop
(restConvergeLiveBound) entirely, so test_deaf_live_bound_note_converges_via_socket_replay
below stages the previously-intermittent wedge DETERMINISTICALLY: room killed
server-side + the note's next vault fan-out dropped, so the note is provably
deaf and only the socket seq-replay re-handshake (gap-heal) can converge it.
The oracle is REST-ABSENCE: no "REST converge" client-log line may touch the
note. A pre-D3 plugin (still leaning on the REST backstop) fails this gate;
a post-D3 plugin with a broken handshake path times out on content.
"""

from __future__ import annotations

import os
import time

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

    # B must converge on the LIVE CRDT fan-out alone: the remote edit arrives AND
    # the preserved base survives the live-bound merge. No catch-up is driven.
    #
    # This previously fell back to `trigger_full_sync()` when the base went
    # missing, asserting only the EVENTUALLY-converged state that the catch-up
    # backstop guarantees (Engram-obsidian#256, a live-merge race that reproduces
    # only under the CI runners' parallel churn). That fallback is gone: the
    # backstop it leaned on (catchUp -> restConvergeLiveBound) is REST, and the
    # sync path is converging on ONE socket CRDT path — a test that heals itself
    # over REST permanently hides live-path data loss, which is the very class of
    # bug #256 is. The live path is the product guarantee, so assert it directly.
    #
    # Engram-obsidian#256 fix: the 3s drift repair could truncate a live-bound
    # editor down to an orphaned/empty Y.Text (base deleted, then autosaved); it
    # now rebinds instead. If this test goes red under churn, that is the
    # reproduction that never surfaced locally — look for the client log line
    # `drift repair SKIPPED` to tell a healed orphan apart from a second,
    # still-unknown mechanism. That line ships over the client-log endpoint
    # (`api_sync.get_logs()`, the source helpers/log_oracle.py mines), NOT the
    # `plugin.log` CI artifact, which is build output only.
    #
    # Wait for each marker separately: `wait_for_content` returns the snapshot at
    # the instant its own marker appears, and the live path may materialize the
    # edit and the base in two flushes. Waiting for base separately asserts the
    # CONVERGED state instead of one instant, without driving a catch-up.
    wait_for_content(vault_b, path, "EDIT-WHILE-B-LIVE-BOUND", timeout=CRDT_TIMEOUT)
    final = wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base content lost on B via the LIVE path: {final!r}"
    assert "EDIT-WHILE-B-LIVE-BOUND" in final, f"remote edit lost on B: {final!r}"


def _wait_for_log(api_sync, needle: str, timeout: float) -> None:
    """Poll client logs until any line contains `needle` (id-agnostic: the
    gap-heal fire line is throttle-coalesced and may name another note)."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        logs = api_sync.get_logs(limit=1000).get("logs", [])
        if any(needle in log.get("message", "") for log in logs):
            return
        time.sleep(1)
    raise TimeoutError(f"no {needle!r} client log within {timeout}s")


@pytest.mark.asyncio
async def test_deaf_live_bound_note_converges_via_socket_replay(vault_b, cdp_b, api_sync):
    """D3 gate (single-path CRDT): the 2026-07-14 deaf-note class heals over
    the SOCKET alone — no REST converge, no full sync.

    Stage: X live-bound in B's editor; X's server room killed (B silently no
    longer an observer — the prod deafness) AND X's next vault fan-out
    swallowed (FanoutPacer.test_drop_next — the lost-broadcast class). A REST
    edit to X then materializes server-side with a bumped vault seq B never
    sees; a trigger edit to Y delivers a later seq, B detects it is behind,
    and the seq replay's live-bound leg re-handshakes (STEP1 recreates the
    room, STEP2 delivers the missing ops). Convergence may also ride a later
    idle full-state fan-out for X (not dropped; also socket) — the gate's
    oracle is REST-ABSENCE, not which socket carrier won.

    Replaces test_deaf_live_bound_note_converges_via_rest_catchup: the REST
    backstop (restConvergeLiveBound) is DELETED in the paired plugin PR, so
    the handshake budget is NOT zeroed here — STEP1 is the heal path. A
    pre-D3 plugin fails the REST-absence oracle; a post-D3 plugin with a
    broken handshake path times out on content.
    """
    path_x = "E2E/Crdt/DeafLiveBound.md"
    path_y = "E2E/Crdt/DeafLiveTrigger.md"

    api_sync.create_note(path_x, "# Deaf Live Bound\nbase line.\n")
    api_sync.create_note(path_y, "# Deaf Live Trigger\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path_x, "base line", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path_y, "base line", timeout=CRDT_TIMEOUT)

    # Live-bind X in B's editor BEFORE the wedge, so B's Y.Doc owns it.
    opened = await cdp_b.evaluate(
        """
        (async () => {
          const f = app.vault.getAbstractFileByPath(%r);
          if (!f) return "no-file";
          await app.workspace.getLeaf(false).openFile(f);
          return app.workspace.activeEditor?.file?.path ?? "no-active";
        })()
        """
        % path_x,
        await_promise=True,
    )
    assert opened == path_x, f"failed to live-bind note in Obsidian editor: {opened!r}"

    note_id_x = _note_id(api_sync, path_x)
    # Stage the deafness: room dead (B silently unobserved) + next fan-out lost.
    backend_rpc(f'Engram.Notes.CrdtRegistry.terminate_room("{note_id_x}")')
    backend_rpc(f'Engram.Notes.FanoutPacer.test_drop_next("{note_id_x}", 1)')

    api_sync.append_note(path_x, "\nEDIT-WHILE-B-DEAF\n")
    api_sync.wait_for_note_content(path_x, "EDIT-WHILE-B-DEAF", timeout=CRDT_TIMEOUT)
    # Trigger: Y's delivered fan-out carries a later vault seq — B is provably
    # behind and must self-heal. NO trigger_full_sync from here on.
    api_sync.append_note(path_y, "\nTRIGGER-EDIT-Y\n")

    final = wait_for_content(vault_b, path_x, "EDIT-WHILE-B-DEAF", timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base content lost on B: {final!r}"
    wait_for_content(vault_b, path_y, "TRIGGER-EDIT-Y", timeout=CRDT_TIMEOUT)

    # Mechanism oracles: a heal fired, and NO REST converge line touched X.
    _wait_for_log(api_sync, "gap-heal fired", timeout=CRDT_TIMEOUT)
    logs = api_sync.get_logs(limit=1000).get("logs", [])
    rest_lines = [
        log["message"]
        for log in logs
        if "REST converge" in log.get("message", "") and path_x in log.get("message", "")
    ]
    assert not rest_lines, f"REST converge ran for {path_x}: {rest_lines}"
