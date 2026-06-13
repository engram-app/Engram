"""Test 77: 1k-note bulk first sync lands via the batch endpoint in bounded time.

Protocol rev: pushAll sends notes through POST /notes/batch in chunks of
100 — a 1,000-note first sync is ~10 HTTP round-trips instead of 1,000.
The duration bound is deliberately generous for CI noise but far below
what the per-note path costs (1,000 paced requests), so a silent fallback
to per-note pushes fails this test.
"""

import time

import pytest

from helpers.vault import write_note

NOTE_COUNT = 1000
PUSH_TIME_BOUND_S = 120


@pytest.mark.asyncio
async def test_bulk_first_sync_timing(vault_a, cdp_a, api_sync):
    # Seed 1,000 files on disk, then wait for Obsidian's indexer to see them
    # (raw filesystem writes only reach app.vault.getFiles() once the
    # watcher fires).
    for i in range(NOTE_COUNT):
        write_note(
            vault_a,
            f"Bulk/n{i:04d}.md",
            f"# Bulk note {i}\n\nfirst-sync payload {i}",
        )

    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        count = await cdp_a.evaluate(
            "app.vault.getFiles().filter(f => f.path.startsWith('Bulk/')).length"
        )
        if isinstance(count, int) and count >= NOTE_COUNT:
            break
        time.sleep(1)
    else:
        raise TimeoutError(f"Obsidian indexed only {count}/{NOTE_COUNT} bulk files")

    started = time.monotonic()
    result = await cdp_a.trigger_full_sync()
    elapsed = time.monotonic() - started

    assert result.get("pushed", 0) >= NOTE_COUNT, f"fullSync result: {result}"
    assert elapsed < PUSH_TIME_BOUND_S, (
        f"bulk first sync took {elapsed:.1f}s (bound {PUSH_TIME_BOUND_S}s) — "
        "did the plugin fall back to per-note pushes?"
    )

    # Server-side proof: every note is in the manifest.
    manifest = api_sync.get_manifest()
    bulk_paths = [n["path"] for n in manifest["notes"] if n["path"].startswith("Bulk/")]
    assert len(bulk_paths) >= NOTE_COUNT, (
        f"manifest holds {len(bulk_paths)}/{NOTE_COUNT} bulk notes"
    )
