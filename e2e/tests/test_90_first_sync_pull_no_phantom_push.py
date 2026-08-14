"""Test 90: a pull materialises every note and pushes nothing back.

The 2026-08-13 prod first sync produced two user-visible lies at once:

  * folders appeared, notes did not (`flushFromCrdt` returned true while the
    sync gate was shut, having written nothing, so the replay counted phantom
    writes and the progress bar filled to 100% in 0.25s)
  * it then announced ~122 files to UPLOAD from a vault that had started empty

The second is the more dangerous one. Those notes had just been pulled FROM the
server; offering to push them back means the client did not recognise them as
server-known, and the next step from "offer to upload" is "upload duplicates".

`fullSync()` returns `{pulled, pushed}`, so both halves are one assertion each.
`pushed == 0` is the real regression fence: it fails the moment a materialised
note stops being marked server-known, which is exactly the #339 defect.

Deliberately NOT written against a pristine vault. The defect is "a note this
client just wrote to disk from the server looks locally-originated", which
reproduces against any vault as long as the notes are new to this device.
"""

from __future__ import annotations

import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content

NOTE_COUNT = 6


@pytest.mark.asyncio
async def test_pull_materialises_every_note_and_pushes_none(vault_b, cdp_b, api_sync):
    run = uuid.uuid4().hex[:12]
    paths = [f"E2E/PullNoPush-{run}/N{i}.md" for i in range(NOTE_COUNT)]

    # Settle first so the counts below describe THIS test's work, not a backlog
    # left by whatever ran before it in the session.
    await cdp_b.accept_sync_gate()
    await cdp_b.trigger_full_sync()

    try:
        for i, path in enumerate(paths):
            api_sync.create_note(path, f"# N{i}\npull-marker-{i}\n")

        result = await cdp_b.trigger_full_sync()

        # Every note on disk with the right body. Folders arriving without notes
        # was the visible symptom; content equality is what proves a real write
        # rather than a touched empty file.
        for i, path in enumerate(paths):
            wait_for_content(
                vault_b, path, f"pull-marker-{i}", timeout=DELIVERY_TIMEOUT
            )

        # Deliberately NOT asserting on `pulled`. This device is live-connected,
        # so `create_note` fans out over the socket and the plugin applies each
        # row on arrival; by the time the explicit sync runs there is nothing
        # left to replay and `pulled` is legitimately 0. An earlier cut asserted
        # `pulled >= NOTE_COUNT` and failed in CI for exactly that reason — it
        # was pinning WHICH ROUTE delivered, which is not a property of the fix
        # and is a race between fan-out and the sync call. Materialisation is
        # already proven above, and the replay route specifically is fenced by
        # test_89 (gate closed, then opened) where fan-out cannot short-circuit
        # it.
        #
        # The fence. A freshly pulled note must never look like a local original.
        assert result.get("pushed", 0) == 0, (
            f"pushed={result.get('pushed')} after a pure pull — notes pulled FROM "
            "the server are being offered back TO it (the phantom-upload defect)"
        )
    finally:
        for path in paths:
            try:
                api_sync.delete_note(path)
            except Exception:  # noqa: BLE001 - teardown must not mask the failure
                pass
