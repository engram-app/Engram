"""Test 103: a keep-both conflict copy must reach the server and stay on disk.

engram-app/Engram#1931: when a server change meets an unpushed local edit, the
plugin saves the local edit as a `(conflict ...)` sibling. It stamped that copy
"synced" without ever uploading it, so the push path echo-skipped it and the
next manifest reconcile trashed it as server-deleted. The local edit, the
thing keep-both exists to protect, ended up in the trash.

Scenario: the note is edited while outgoing sync is paused, then deleted on
the server. The live tombstone meets the unpushed edit and forces keep-both.
"""

from __future__ import annotations

import asyncio
import json
import time
import uuid

import pytest

from helpers.vault import read_note, write_note

FOLDER = "E2E/ConflictCopy103"


@pytest.mark.asyncio
async def test_conflict_copy_is_pushed_not_trashed(vault_a, cdp_a, api_sync):
    tag = uuid.uuid4().hex[:8]
    path = f"{FOLDER}/Kept-{tag}.md"
    edited = f"# Kept {tag}\nlocal edit the server never saw\n"

    write_note(vault_a, path, f"# Kept {tag}\nbaseline\n")
    api_sync.wait_for_note(path, timeout=30)
    await cdp_a.wait_for_note_id_for_path(path)
    # The server row can appear before the create push settles locally. Edit
    # before that and the delete meets an unsettled baseline, not drift.
    se = "app.plugins.plugins['engram-vault-sync'].syncEngine"
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        if await cdp_a.evaluate(
            f"!{se}.pushing.has({json.dumps(path)}) && {se}.syncState.has({json.dumps(path)})"
        ):
            break
        await asyncio.sleep(0.3)
    else:
        raise TimeoutError(f"create push for {path} never settled")
    await asyncio.sleep(1)

    await cdp_a.evaluate(
        "window.__c103 = []; "
        "window.__c103Ref = app.vault.on('create', f => window.__c103.push(f.path)); true"
    )
    # vault_write fires the modify event synchronously, so the paused handler
    # drops it. The server delete lands inside the same pause, before any
    # periodic scan can push the edit (a pause-then-resume-then-delete order
    # let a scan push it under full-suite load, so no conflict formed).
    await cdp_a.pause_outgoing_sync()
    try:
        await cdp_a.vault_write(path, edited)
        assert api_sync.delete_note(path) in (200, 204)
        copy = None
        deadline = time.monotonic() + 30
        while time.monotonic() < deadline and copy is None:
            created = json.loads(
                await cdp_a.evaluate("JSON.stringify(window.__c103)") or "[]"
            )
            copy = next(
                (p for p in created if p.startswith(f"{FOLDER}/Kept-{tag} (conflict")),
                None,
            )
            await asyncio.sleep(0.3)
    finally:
        await cdp_a.resume_outgoing_sync()
        await cdp_a.evaluate("app.vault.offref(window.__c103Ref); true")

    # Vacuous-pass guard: without a copy this run never reached keep-both.
    assert copy, "server delete over an unpushed edit wrote no keep-both copy"

    # A full sync runs the manifest reconcile that trashed the copy in #1931,
    # and the push scan that must upload it.
    await cdp_a.trigger_full_sync()
    await asyncio.sleep(3)

    assert (vault_a / copy).exists(), (
        f"keep-both copy {copy} was removed from disk; the unpushed local edit "
        "is now only in the trash (engram-app/Engram#1931)"
    )
    assert read_note(vault_a, copy) == edited
    api_sync.wait_for_note(copy, timeout=30)
