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

Crosses the boundary with DATA VOLUME rather than by shrinking the budget on the
backend. An earlier draft used `backend_rpc` to set `:sync_page_max_bytes` low;
that is process-global on a shared node, and the suite runs under 2-worker
xdist, so it would have silently forced a sibling worker's vault to one note per
page. This version also has the better property of exercising the budget that
actually ships.
"""

from __future__ import annotations

import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import wait_for_content

# Default budget is 4 MB. 9 x 600 KB = ~5.4 MB, so the feed must split at least
# once. Deliberately modest: the property under test is "a boundary happens and
# nothing is lost", which two pages prove as well as twenty, and every extra
# megabyte here is real upload plus an embedding job on a shared CI backend.
NOTE_COUNT = 9
NOTE_KB = 600


@pytest.mark.asyncio
async def test_every_note_survives_a_paged_first_sync(vault_b, cdp_b, api_sync):
    run = uuid.uuid4().hex[:12]
    paths = [f"E2E/Budget-{run}/B{i}.md" for i in range(NOTE_COUNT)]
    # Encrypted at rest, so the stored ciphertext this is measured against is
    # incompressible regardless of how repetitive the plaintext looks.
    body = "x" * (NOTE_KB * 1024)

    await cdp_b.accept_sync_gate()
    await cdp_b.trigger_full_sync()

    try:
        for i, path in enumerate(paths):
            api_sync.create_note(path, f"budget-marker-{i}\n{body}")

        await cdp_b.trigger_full_sync()

        # Every note, across every page boundary. A missing one here is the
        # merge-watermark failure: the cursor stepped over notes the budget held
        # back, and they are unreachable from that cursor forever.
        for i, path in enumerate(paths):
            wait_for_content(
                vault_b, path, f"budget-marker-{i}", timeout=DELIVERY_TIMEOUT
            )
    finally:
        for path in paths:
            try:
                api_sync.delete_note(path)
            except Exception:  # noqa: BLE001 - teardown must not mask the failure
                pass
