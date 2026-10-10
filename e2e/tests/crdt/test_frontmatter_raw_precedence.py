"""A web-app property edit must win over a key's stored raw YAML text.

engram-app/Engram#1928, the suspected live bug found while mapping fix 2.

A key whose YAML the backend cannot encode as a value ("degraded", e.g. a
flow map with a list key) is kept verbatim in the `frontmatter_raw` Y.Map,
and BOTH projections render the raw span in preference to the value
(plugin `frontmatter-codec.ts` emitFrontmatter, backend `Frontmatter.emit/3`).

The web properties widget lists every key in `frontmatter_order`, including
degraded ones, and `setValue` writes only the values map. It never clears the
raw entry. So the edit lands in the doc and is then invisible: every
projection still renders the old raw text, on the server and on disk.

The control key (`status`) is edited in the same session and arrives first,
so a failure on `date` cannot be a delivery delay.
"""

from __future__ import annotations

import os

import pytest
from playwright.async_api import expect

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import read_note, wait_for_content

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

MS = DELIVERY_TIMEOUT * 1_000
DEGRADED = "date: {[a, b]: 1}"


def _note_id(api_sync, path: str) -> str:
    note = api_sync.wait_for_note(path, timeout=DELIVERY_TIMEOUT)
    inner = note.get("note", note) if isinstance(note, dict) else {}
    nid = inner.get("id") or inner.get("note_id") or inner.get("uuid")
    assert nid, f"no note id in {note!r}"
    return nid


@pytest.mark.asyncio
async def test_web_edit_of_degraded_key_reaches_obsidian(
    vault_b, cdp_b, api_sync, web, sync_vault_id
):
    path = "E2E/Crdt/FmRawPrecedence.md"
    api_sync.create_note(path, f"---\nstatus: draft\n{DEGRADED}\n---\n\nbase line.\n")
    await cdp_b.trigger_full_sync()
    seeded = wait_for_content(vault_b, path, "base line", timeout=DELIVERY_TIMEOUT)
    assert DEGRADED in seeded, f"fixture did not keep the raw span: {seeded!r}"

    note_id = _note_id(api_sync, path)
    await web.open_note(note_id, sync_vault_id)
    await expect(web.property_value_locator("status")).to_have_value(
        "draft", timeout=MS
    )

    await web.set_property("date", "2026-10-10")
    # The widget took the edit: this rules out a read-only degraded row.
    await expect(web.property_value_locator("date")).to_have_value(
        "2026-10-10", timeout=MS
    )
    await web.set_property("status", "published")

    # Control: a plain key edited AFTER the degraded one has arrived.
    await cdp_b.trigger_full_sync()
    disk = wait_for_content(vault_b, path, "published", timeout=DELIVERY_TIMEOUT)
    disk = read_note(vault_b, path)

    assert "2026-10-10" in disk and DEGRADED not in disk, (
        "the web edit of `date` was silently reverted: the plain key `status` "
        "synced, but `date` still projects its stored raw text because setValue "
        f"never clears frontmatter_raw. Disk:\n{disk!r}"
    )
