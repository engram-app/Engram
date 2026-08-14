"""Test 92: a byte-budget-split first sync delivers every note.

The catch-up page now stops at a byte budget as well as a row count, because a
500-row page of 10 MB notes would try to build ~5 GB inside an 820 MB container
and OOM the task — taking every other user on that node down with it.

Splitting a feed is a data-loss risk, not just a perf change, and this one had a
real one in it. Notes and attachments are two feeds merged by seq. Capping the
notes feed by bytes lets it stop at seq 5 while the unbudgeted attachments feed
still returns rows up to seq 500; emitting those advances the shared cursor past
notes that were never fetched, and the client resumes AFTER them. Skipped, not
delayed. A watermark in `merged_changes_page` clamps that, and a unit test pins
it — but only a real client walking real pages proves the walk terminates and
converges.

Staged by shrinking the budget on the running backend so an ordinary test vault
splits into many pages. Restored in the teardown; the assertion is simply that
nothing is missing afterwards.
"""

from __future__ import annotations

import uuid

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content

NOTE_COUNT = 12
NOTE_KB = 8
# Below one note, so every page carries exactly one row and the client has to
# make NOTE_COUNT round trips. Maximum paging pressure for a small fixture.
TINY_BUDGET = 2 * 1024


def _set_budget(value: str) -> None:
    backend_rpc(f"Application.put_env(:engram, :sync_page_max_bytes, {value})")


@pytest.mark.asyncio
async def test_every_note_survives_a_heavily_paged_first_sync(vault_b, cdp_b, api_sync):
    run = uuid.uuid4().hex[:12]
    paths = [f"E2E/Budget-{run}/B{i}.md" for i in range(NOTE_COUNT)]
    body = "x" * (NOTE_KB * 1024)

    await cdp_b.accept_sync_gate()
    await cdp_b.trigger_full_sync()

    for i, path in enumerate(paths):
        api_sync.create_note(path, f"budget-marker-{i}\n{body}")

    _set_budget(str(TINY_BUDGET))
    try:
        await cdp_b.trigger_full_sync()

        # Every note, across every page boundary. A dropped row here is the
        # merge-watermark failure: the cursor stepped over notes the budget had
        # held back and they are unreachable from that cursor forever.
        for i, path in enumerate(paths):
            wait_for_content(
                vault_b, path, f"budget-marker-{i}", timeout=DELIVERY_TIMEOUT
            )
    finally:
        # Back to the configured default before anything else runs, or every
        # later test in the session pays one round trip per note.
        _set_budget("4 * 1024 * 1024")
        for path in paths:
            try:
                api_sync.delete_note(path)
            except Exception:  # noqa: BLE001 - teardown must not mask the failure
                pass
