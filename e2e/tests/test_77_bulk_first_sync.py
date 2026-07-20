"""Test 77: 1k-note bulk first sync lands via crdt_create_batch in bounded time.

CRDT single-push-path migration: pushGenesisBatch sends notes through the
WS `crdt_create_batch` op in chunks, not POST /notes/batch (removed) — a
1,000-note first sync is a handful of socket round-trips instead of 1,000.
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
    # Close the sync gate FIRST: every raw write below fires the vault
    # watcher, and an open gate turns that into 1,000 debounced single-note
    # auto-pushes — a request storm that exhausts the rate budget and
    # starves the batch sync this test measures. handleModify short-circuits
    # while the gate is closed.
    await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked(true)"
    )

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

    # Re-open the gate the same way a user accepting the PreSync modal does
    # (persists the fingerprint + flips syncBlocked false).
    await cdp_a.accept_sync_gate()

    # Drive the bulk first sync to server-side convergence within the time
    # bound. A single fullSync()'s `pushed` count is an unreliable proxy under
    # CI load, in two ways (both observed as issue #627):
    #   1. fullSync() returns {pulled:0, pushed:0} when syncBlocked is still
    #      true — the plugin's async startup can re-assert it AFTER our unblock.
    #   2. A batch chunk that errors against a loaded backend goes offline with
    #      the remainder queued (sync.ts pushNotesViaBatch), so one call can
    #      report a partial count (e.g. pushed=2) even though the rest land
    #      moments later.
    # So we re-assert unblocked and re-trigger fullSync until the SERVER
    # manifest holds all 1,000 notes, bounded by PUSH_TIME_BOUND_S. The bound
    # is the batch-vs-per-note guarantee: 1,000 paced per-note pushes cannot
    # converge within it, so a silent fallback still fails this test — the
    # success criterion is "bulk lands in bounded time", not a single call's
    # push tally.
    unblock = (
        "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked(false)"
    )
    started = time.monotonic()
    deadline = started + PUSH_TIME_BOUND_S
    bulk_count = 0
    while time.monotonic() < deadline:
        await cdp_a.evaluate(unblock)
        await cdp_a.trigger_full_sync()
        manifest = api_sync.get_manifest()
        bulk_count = sum(
            1 for n in manifest["notes"] if n["path"].startswith("Bulk/")
        )
        if bulk_count >= NOTE_COUNT:
            break
        time.sleep(2)
    elapsed = time.monotonic() - started

    assert bulk_count >= NOTE_COUNT, (
        f"bulk first sync converged only {bulk_count}/{NOTE_COUNT} notes in "
        f"{elapsed:.1f}s (bound {PUSH_TIME_BOUND_S}s) — did the plugin fall "
        "back to per-note pushes or stall?"
    )
