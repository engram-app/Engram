"""Test 77: 1k-note bulk first sync lands via crdt_create_batch in bounded time.

CRDT single-push-path migration: pushGenesisBatch sends notes through the
WS `crdt_create_batch` op in chunks, not POST /notes/batch (removed) — a
1,000-note first sync is a handful of socket round-trips instead of 1,000.
The duration bound is deliberately generous for CI noise but far below
what the per-note path costs (1,000 paced requests), so a silent fallback
to per-note pushes fails this test.
"""

import shutil
import time

import pytest

from helpers.vault import write_note

NOTE_COUNT = 1000
PUSH_TIME_BOUND_S = 120

SET_BLOCKED = "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"


async def _cleanup_bulk_residue(vault_a, cdp_a, api_sync) -> None:
    """Remove this test's 1,000 Bulk/* notes from the session vault.

    Fixtures are session-scoped (conftest) and only Clerk USERS are swept
    between runs — vault notes persist. Left behind, these 1,000 notes storm
    a later run's test_66: reconnect churn re-handshakes them (~454/window,
    the #193 handshake-budget class), saturating the /logs pipeline past
    test_66's 5s delivery budget (#1093, rerun-safety playbook §5). Deleting
    both sides (local files + server rows) keeps the session vault clean.

    Server rows go via POST /notes/batch-delete (one idempotent request over
    the manifest's ids), not 1,000 paced DELETEs — no time budget, no
    rate-limit starvation, deletes every note in one shot.

    The whole body is guarded: teardown must never fail or hang the suite. If
    CDP/Obsidian died (the reason the test failed), swallowing here keeps the
    real AssertionError as the headline instead of a chained cleanup error.
    Gate closed first so the local unlink doesn't fan out 1,000 delete-pushes.
    """
    try:
        await cdp_a.evaluate(SET_BLOCKED.format("true"))
        shutil.rmtree(vault_a / "Bulk", ignore_errors=True)

        manifest = api_sync.get_manifest()
        ids = [
            n["id"]
            for n in manifest.get("notes", [])
            if n.get("id") and n.get("path", "").startswith("Bulk/")
        ]
        # Chunk so one oversized body can't trip a request-size limit.
        for start in range(0, len(ids), 500):
            api_sync.batch_delete_notes(ids[start : start + 500])

        # Re-open the gate so subsequent tests sync normally.
        await cdp_a.evaluate(SET_BLOCKED.format("false"))
    except Exception:  # teardown is strictly best-effort — never mask the real failure
        pass


@pytest.mark.asyncio
async def test_bulk_first_sync_timing(vault_a, cdp_a, api_sync):
    try:
        # Close the sync gate FIRST: every raw write below fires the vault
        # watcher, and an open gate turns that into 1,000 debounced single-note
        # auto-pushes — a request storm that exhausts the rate budget and
        # starves the batch sync this test measures. handleModify short-circuits
        # while the gate is closed.
        await cdp_a.evaluate(SET_BLOCKED.format("true"))

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
        started = time.monotonic()
        deadline = started + PUSH_TIME_BOUND_S
        bulk_count = 0
        while time.monotonic() < deadline:
            await cdp_a.evaluate(SET_BLOCKED.format("false"))
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
    finally:
        await _cleanup_bulk_residue(vault_a, cdp_a, api_sync)
