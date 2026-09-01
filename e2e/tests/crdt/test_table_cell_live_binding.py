"""Reproduces engram-app/Engram-obsidian#487: clicking a table cell in Live
Preview pasted the ENTIRE note body into that cell, froze Obsidian, and synced
the corruption to the server.

Mechanism. `registerEditorExtension` installs the CRDT live binding into every
CM6 EditorView Obsidian builds. The Live Preview table widget builds a NESTED
EditorView per cell (`editor.tableCell.cm`) and constructs it with the PARENT
editor's `owner`, so `editorInfoField` inside a cell resolves to the same
MarkdownView and the same `file.path`. The binding keyed only off that path, so
the cell's tiny view bound to the whole note's Y.Text; the initial reconcile read
"editor is stale disk, doc is authoritative", took the `adopt` branch, and
painted the whole document into the cell. Obsidian's table code then round-tripped
that back into the real file, and the sync engine pushed it.

Why these tests need the CRDT stack: without a coordinator the binding is inert,
so the bug cannot occur and the test would pass for the wrong reason.

The oracles, weakest to strongest:
  1. `cellEditor` — a HARD staging gate. If the click never built a cell editor,
     nothing was exercised and the test fails instead of passing vacuously.
  2. viewer count — the direct fix oracle. One open note is one bound view. The
     cell must not become a second one.
  3. disk + server content — the user-visible corruption. Byte-exact.
"""

from __future__ import annotations

import os
import time

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import read_note, write_note

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = DELIVERY_TIMEOUT

PATH = "E2E/Crdt/TableCell487.md"

# A body long enough that whole-document duplication is unmistakable, and a
# table whose cells are SHORT so an adopted body cannot be confused for one.
BODY = "\n".join(
    [
        "# Table Cell 487",
        "",
        "Prose above the table that must never appear inside it. " * 6,
        "",
        "| Time | Beat  | You see |",
        "| ---- | ----- | ------- |",
        "| 0:00 | Cold  | webcam  |",
        "| 0:45 | Sync  | three   |",
        "| 1:30 | Close | webcam  |",
        "",
        "Prose below the table, also load-bearing for the assertion. " * 6,
        "",
    ]
)

# The document is corrupted the moment a table row contains text that only ever
# existed outside the table. Obsidian serializes the newlines as <br>, so match
# on the prose itself rather than on a line shape.
CORRUPTION_MARKERS = ("Prose above the table", "# Table Cell 487")


async def _stage_clicked_cell(cdp, vault, api, cell_text: str) -> tuple[str, dict]:
    """Seed the note, sync it, open it in Live Preview, click a cell.

    Returns the exact content that must survive. Fails loudly at every step that
    could otherwise leave a later assertion trivially true.
    """
    write_note(vault, PATH, BODY)
    api.wait_for_note_content(PATH, "Prose above the table", timeout=CRDT_TIMEOUT)
    on_disk = read_note(vault, PATH)

    opened = await cdp.open_note_in_live_preview(PATH)
    assert opened == PATH, f"failed to open {PATH} in Live Preview: {opened!r}"

    # One open note == one bound view. If this is not true the staging is wrong
    # and the count assertion below would be measuring something else.
    baseline = await cdp.live_viewer_count(PATH)
    assert baseline == 1, (
        f"expected exactly 1 live-bound view for the open note, got {baseline} "
        "(-1 means the CRDT layer never wired up — check E2E_ENABLE_CRDT)"
    )

    result = await cdp.enter_table_cell(cell_text)
    assert result.get("cellEditor"), (
        f"entering the table cell never opened a nested cell editor: {result!r}. "
        "Nothing was staged — this is a harness failure, not a passing product."
    )
    return on_disk, result


@pytest.mark.asyncio
async def test_table_cell_does_not_bind_a_second_view(vault_a, cdp_a, api_sync):
    """The nested cell editor must not live-bind the note (the root cause)."""
    await _stage_clicked_cell(cdp_a, vault_a, api_sync, "three")

    count = await cdp_a.live_viewer_count(PATH)
    assert count == 1, (
        f"the table-cell editor live-bound as viewer #{count} for {PATH}. "
        "Obsidian builds it with the parent editor's owner, so editorInfoField "
        "resolves to the same file — the binding must reject any EditorView that "
        "is not the owner's own editor."
    )


@pytest.mark.asyncio
async def test_table_cell_click_does_not_duplicate_the_document(
    vault_a, cdp_a, api_sync
):
    """The user-visible bug: the whole body pasted into the clicked cell."""
    original, staged = await _stage_clicked_cell(cdp_a, vault_a, api_sync, "webcam")

    # The clearest form of the bug: the cell editor's own document IS the note.
    assert staged["cellLen"] < 64, (
        f"the cell editor holds {staged['cellLen']} chars — the whole note was "
        f"adopted into one cell: {staged['cellText'][:200]!r}"
    )

    # The corruption was immediate (the reconcile runs on attach), but the 3s
    # drift backstop is the other writer that could produce it. Wait past it so a
    # green result covers both, then let any push settle.
    time.sleep(6)

    cell = await cdp_a.table_cell_text()
    for marker in CORRUPTION_MARKERS:
        assert marker not in cell, (
            f"the table cell holds text from outside the table ({marker!r}); "
            f"cell is {len(cell)} chars: {cell[:200]!r}"
        )

    final = read_note(vault_a, PATH)
    assert final == original, (
        f"the note on disk changed after clicking a table cell "
        f"({len(original)} -> {len(final)} chars)"
    )

    # And the corruption must not have reached the server either.
    remote = api_sync.get_note(PATH)
    remote_content = (remote or {}).get("note", remote or {}).get("content", "")
    assert len(remote_content) <= len(original) + 64, (
        f"the server copy grew after a table-cell click "
        f"({len(original)} -> {len(remote_content)} chars) — the duplication synced"
    )
    for marker in ("| 0:45 | Sync", "| 1:30 | Close"):
        assert marker.split("|")[1].strip() in remote_content, (
            f"table row {marker!r} missing from the server copy"
        )
