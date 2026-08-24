"""Test 77: a 1k-note bulk first sync lands in bounded time, and does not
allocate a CRDT room per note.

Push path: `pushPartitioned` -> `pushFile` -> socket-native `crdt_create`,
one bounded per-file work unit each (the `crdt_create_batch` RPC this test
was originally written against was retired in the Relay-pattern rewrite, in
favour of per-file failure isolation). The duration bound is deliberately
generous for CI noise but far below what a REST per-note fallback costs
(1,000 paced requests), so a silent regression to that path fails here.

The room-allocation bound is the #1409 acceptance criterion. A room is a
live-collaboration actor; an import has no collaborators, so genesis content
is seeded detached (#1424) and rooms should be allocated only for notes
actually open in an editor. Importing a 1,700-file vault once allocated
~1,700 rooms and took prod's BEAM from 757 to 2,744 processes (2026-08-18).
"""

import shutil
import time

import pytest

from helpers.room_probe import arm_room_starts, read_room_starts
from helpers.vault import write_note

NOTE_COUNT = 1000
PUSH_TIME_BOUND_S = 120

# Rooms this sync may allocate. The criterion is O(open editors), not O(N) —
# the bound is a small constant on purpose, so a per-note regression fails by
# two orders of magnitude rather than by a tuning argument. Raising this is
# only correct alongside a reason a first sync needs more live actors.
#
# MEASURED 0 locally on 0.18.0 (2026-08-20, 1,000 notes): with the genesis body
# riding `crdt_create` (#1424 + plugin #452) the import never sends a `crdt_msg`,
# and `crdt_msg` is what calls `ensure_room`. The headroom above 0 covers a note
# open in the editor during the run and any seed that falls back to the
# `crdt_msg` path (`seeded: false`, e.g. an ADOPT) — both allocate legitimately.
#
# Bounds `crdt_msg`-driven allocation ONLY (handshake is asserted separately
# below). The local 0 did not hold in CI, which measured 544 HANDSHAKE rooms for
# the same 1,000 notes — enrolment, not cold sends. Bounding the total at 8 would
# therefore have asserted that #1409 is fully fixed when only its `crdt_msg` half
# is; the split keeps a real fence on the part that IS fixed instead of a red X
# on the part that is not.
ROOM_ALLOC_BOUND = 8

# Enrolment-driven rooms, the OPEN half of #1409. Recorded as a ratchet, not a
# target: it exists so a change that makes enrolment WORSE fails, while the
# known-open O(N) baseline does not spend every run red.
#
# THIS NUMBER IS HIGHLY VARIABLE — do not read it as a property of the code.
# Measured on 2026-08-24 against the SAME commit, twice:
#     run 32774859300 -> 335 rooms / 1000 notes
#     run 32778220678 ->  57 rooms / 1000 notes
# against a 544/1000 baseline on 2026-08-23 (before plugin #466 gated the
# create-ack self-heal's reset+enroll on isLiveBound).
#
# 335 vs 57 on identical code means this tracks run conditions — reconnects,
# load, socket churn — as much as it tracks enrolment logic. So the bound is
# deliberately set well above the worst OBSERVED value rather than snugly above
# the best: a tight bound here buys a flaky job, not a real fence. It still
# fails loudly on a return to the O(N)-per-note shape this issue is about.
#
# Attribution on the 57-room run (client enroll() bucketed by caller):
#     fireCrdtReHandshake 20, applyChange 6  -> 26 enroll() calls for 57 rooms.
# More than half the rooms never go through enroll(); the suspected path is
# NoteProvider.setConnected(true) re-firing syncStep1 for every resident
# advertised doc on a reconnect edge. See the #1409 thread.
#
# Re-measure by setting this to 0 on a throwaway branch — test_77 prints its
# room split only on failure.
HANDSHAKE_ROOM_RATCHET = 400

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
        # Arm BEFORE the gate work: the counter is cumulative per node and the
        # measured window is a delta, so arming early only widens what is
        # attributed to this test — it can never under-count the sync.
        arm_room_starts()
        rooms_before = read_room_starts()

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

        # Read AFTER convergence: a room allocated by the tail of the sync must
        # be counted, and the drain means residency would already have shed it.
        rooms = read_room_starts() - rooms_before
        print(f"\ntest_77 rooms allocated for {NOTE_COUNT} notes: {rooms}")
        cold_rooms = rooms.edit + rooms.create_batch + rooms.unknown
        assert cold_rooms <= ROOM_ALLOC_BOUND, (
            f"bulk first sync of {NOTE_COUNT} notes allocated {rooms} — expected "
            f"<= {ROOM_ALLOC_BOUND} rooms from the crdt_msg paths (#1409: rooms "
            "are for notes open in an editor, not for imported files). The "
            "per-source split names the path that regressed; `unknown` means an "
            "allocation site shipped without a source tag."
        )
        assert rooms.handshake <= HANDSHAKE_ROOM_RATCHET, (
            f"enrolment opened {rooms.handshake} handshake rooms for "
            f"{NOTE_COUNT} notes, past the {HANDSHAKE_ROOM_RATCHET} ratchet. This "
            "is #1409's open half — the ratchet only fails when it gets WORSE."
        )
    finally:
        await _cleanup_bulk_residue(vault_a, cdp_a, api_sync)
