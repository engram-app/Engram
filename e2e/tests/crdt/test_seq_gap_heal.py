"""D2 seq-gap-heal proof (single-path CRDT sync, Phase D2).

A live fan-out that never reaches a device must be healed by the NEXT
delivered op: every live op carries the vault-global `seq`, the plugin
compares it to its persisted catch-up cursor, and a `seq` ahead of the
cursor fires the single-flight socket seq-replay (`crdt_catchup_since`).

Deterministic stage: `FanoutPacer.test_drop_next/2` swallows note X's
fan-out server-side (a lost broadcast — the real-world class behind the
"received=no materialized=no" delivery flakes). A later edit to note Y
fans out normally with a later seq; B is behind, heals, and the replay
carries X's missed edit. No `trigger_full_sync` after the drop — the heal
IS the assertion, and the client-log check pins the mechanism (a pre-D2
plugin converges neither and logs no heal).
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


def _wait_for_heal_log(api_sync, note_ids: tuple[str, ...], timeout: float) -> None:
    """Poll client logs for a gap-heal line naming one of `note_ids`.

    The heal logs the note whose LIVE OP revealed the gap — that is the
    trigger note (or the dropped note's own announce), so accept either.
    """
    deadline = time.time() + timeout
    seen: list[str] = []
    while time.time() < deadline:
        logs = api_sync.get_logs(limit=500).get("logs", [])
        for log in logs:
            message = log.get("message", "")
            if "gap-heal fired" in message:
                seen.append(message)
                if any(f"note={nid}" in message for nid in note_ids):
                    return
        time.sleep(1)
    raise TimeoutError(
        f"no 'gap-heal fired' client log naming {note_ids} within {timeout}s "
        f"(gap-heal lines seen: {seen or 'none'})"
    )


@pytest.mark.asyncio
async def test_dropped_fanout_heals_via_seq_replay(vault_b, cdp_b, api_sync):
    path_x = "E2E/Crdt/SeqGapLost.md"
    path_y = "E2E/Crdt/SeqGapTrigger.md"

    # Establish both notes on B (setup may use full sync; the assertion must not).
    api_sync.create_note(path_x, "# Seq Gap Lost\nbase line.\n")
    api_sync.create_note(path_y, "# Seq Gap Trigger\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path_x, "base line", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path_y, "base line", timeout=CRDT_TIMEOUT)

    note_id_x = _note_id(api_sync, path_x)
    note_id_y = _note_id(api_sync, path_y)

    # Arm the lost broadcast: X's next fan-out is swallowed server-side.
    backend_rpc(f'Engram.Notes.FanoutPacer.test_drop_next("{note_id_x}", 1)')

    # Edit X — the fan-out is dropped; the server materializes the edit but B
    # receives nothing for X.
    api_sync.append_note(path_x, "\nLOST-EDIT-X\n")
    api_sync.wait_for_note_content(path_x, "LOST-EDIT-X", timeout=CRDT_TIMEOUT)

    # Edit Y — delivered normally with a later vault seq. B's cursor is now
    # provably behind; the plugin must fire the seq-replay, which carries X's
    # missed edit. NO full sync from here on.
    api_sync.append_note(path_y, "\nTRIGGER-EDIT-Y\n")

    final_x = wait_for_content(vault_b, path_x, "LOST-EDIT-X", timeout=CRDT_TIMEOUT)
    assert "base line" in final_x, f"base lost on B for {path_x}: {final_x!r}"
    final_y = wait_for_content(vault_b, path_y, "TRIGGER-EDIT-Y", timeout=CRDT_TIMEOUT)
    assert "base line" in final_y, f"base lost on B for {path_y}: {final_y!r}"

    # Pin the MECHANISM, not just the converged content: the plugin must have
    # logged a gap-heal for the vault (content could in principle converge via
    # another backstop; the log line cannot).
    _wait_for_heal_log(api_sync, (note_id_x, note_id_y), timeout=CRDT_TIMEOUT)
