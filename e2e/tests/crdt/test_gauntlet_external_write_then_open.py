"""Gauntlet 7: an external disk write to a CLOSED note, then the note is opened.

Another sim-fuzz finding the sim cannot prove (it stands in for the
CodeMirror binding). A file changed behind Obsidian's back (git pull, another
editor, a sync tool) reaches the plugin as a `modify` event, debounced. If the
note is opened in the editor inside that window, the suspected failure is: the
editor binds the OLD doc, the external content never enters it, and autosave
writes the old body back over the file.

The write is a plain os-level write into the vault folder, never the vault
API. Opened at 0.7 s (inside the debounce) and, as a control, at 3 s.
Asserted: A's disk, B's disk and the server all hold the external content.
"""

from __future__ import annotations

import asyncio
import uuid

import pytest

from helpers.convergence import Expect, await_converged
from helpers.gauntlet import create_notes


@pytest.mark.timeout(600)
@pytest.mark.parametrize("open_after_s", [0.7, 3.0], ids=["inside_debounce", "control_after_3s"])
async def test_external_write_to_closed_note_then_open(gauntlet, open_after_s):
    pair = await gauntlet("gext")
    a = pair.a
    root = f"ExtWrite-{uuid.uuid4().hex[:6]}"
    path = f"{root}/closed.md"
    old = f"old-{root}"
    await create_notes(a.cdp, {path: f"# Closed\n\n{old}\n"})
    await await_converged(pair.api, pair.vaults, root, Expect({path: [old]}))

    new = f"external-{root}"
    (a.vault / path).write_text(f"# Closed\n\n{new}\n", encoding="utf-8")
    await asyncio.sleep(open_after_s)
    assert await a.cdp.open_note_in_live_preview(path) == path

    await await_converged(
        pair.api, pair.vaults, root, Expect({path: [new]}, at_most_once={old}), deadline_s=120
    )
    body = (a.vault / path).read_text(encoding="utf-8")
    assert old not in body, f"the pre-write body came back: {body!r}"
