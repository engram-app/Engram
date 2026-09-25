"""Test 77: a 1k-note bulk first sync lands over socket-native `crdt_create`
(never per-note REST), and does not allocate a CRDT room per note.

Push path: `pushPartitioned` -> `pushFile` -> socket-native `crdt_create`,
one bounded per-file work unit each (the `crdt_create_batch` RPC this test
was originally written against was retired in the Relay-pattern rewrite, in
favour of per-file failure isolation).

The transport claim is asserted by COUNT, not wall clock (route_probe): every
`Bulk/` note must reach the server via `crdt_create`, and zero via per-note
`POST /notes`. This used to be a proxy — "1,000 notes within 120s" — which
flaked ~5/7 nights: on the shared runner pool (two heavy e2e suites per VM) the
whole test took 31s to 153s for identical code, and at the slow end it is as
slow as the REST fallback it was meant to catch. The count separates the two
regardless of load. The remaining deadline is a HANG detector only.

The room-allocation bound is the #1409 acceptance criterion. A room is a
live-collaboration actor; an import has no collaborators, so genesis content
is seeded detached (#1424) and rooms should be allocated only for notes
actually open in an editor. Importing a 1,700-file vault once allocated
~1,700 rooms and took prod's BEAM from 757 to 2,744 processes (2026-08-18).
"""

import asyncio
import json
import os
import shutil
import threading
import time

import pytest

from helpers.residency_probe import read_resident_rooms
from helpers.room_probe import arm_room_starts, read_room_starts
from helpers.route_probe import arm_routes, read_routes
from helpers.vault import write_note

# CI always runs the full 1,000 — the bounds below are calibrated against that
# size and the default must never be lowered. The override exists so the LOCAL
# repro loop (docs/context/local-crdt-e2e-repro.md) can run a smaller import on
# a slow box.
NOTE_COUNT = int(os.environ.get("E2E_BULK_NOTE_COUNT", "1000"))

# HANG detector, not a performance bound — the transport claim is the route
# count. Across 36 CI runs of the same code (2026-09-25) this whole test took 31s
# to 153s, driven by runner contention, and the slowest sync ran ~5 notes/s
# (~200s for 1,000); 200s is sized to that tail while still failing a sync that
# stopped making progress. Do not tighten this into a
# throughput assert again: on a shared pool it measures the neighbours.
CONVERGE_DEADLINE_S = 200

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

# Enrolment-driven rooms, the OPEN half of #1409. A ratchet, not a target: it
# fails when enrolment gets WORSE, and does not spend every run red on the
# known-open O(N) baseline.
#
# THE METRIC IS EXTREMELY NOISY — measure before you tighten this. Observed on
# 2026-08-24/25 across runs of essentially the same code, post plugin #466:
#     57, 81, 335, 583   rooms / 1000 notes
# (baseline was 544 on 2026-08-23, pre-#466.) A 10x spread, because the count
# tracks reconnects and socket churn as much as enrolment logic.
#
# An earlier revision of THIS comment set the bound to 400 off a single 335
# sample. The next run measured 583 and the job went red on a change that had
# regressed nothing. Do not repeat that: a bound near the middle of this range
# buys a flaky job, not a fence. 700 sits above every observed value while still
# failing loudly on a true return to one-room-per-note (which would be ~1000).
#
# Attribution (measured, see the #1409 thread): the rooms are ordinary enroll()
# calls, dominated by fireCrdtReHandshake — which is a DELIVERY path for durably
# queued edits and must NOT be gated to reduce this number. The reconnect
# re-advertise theory was tested and falsified.
#
# Re-measure by setting this to 0 on a throwaway branch: test_77 prints its room
# split only on failure. Also note read_room_starts() counts rooms server-wide
# across ALL THREE Obsidian instances, while any cdp_a-based client probe sees
# only device A — do not compare the two without accounting for that.
HANDSHAKE_ROOM_RATCHET = 700

# Peak CONCURRENT rooms during the import. This is the bound that maps to
# MEMORY, and it is the one #1409's incident was actually about: on 2026-08-18 a
# 1.7k-file import left ~2000 rooms RESIDENT and took prod from 757 to 2744
# processes.
#
# Unlike the allocation ratchet above (10x run-to-run spread), residency is
# tight and stable: MEASURED 4 for 1000 notes on 2026-08-24, twice — once with
# CI's 5s idle drain and once with the drain set to prod's 300s. It did not move,
# because a note room exits on `auto_exit` when its last OBSERVER leaves, not on
# the idle timer; the timer is a backstop for the per-vault index room, which is
# observed for a whole session. Enrolment being gated to live-bound notes is what
# lets observers leave promptly.
#
# 32 is ~8x the observed peak: a real regression to one-resident-room-per-note
# would blow past it by two orders of magnitude, while normal churn stays far
# under. If this ever fails, check whether something started enrolling idle notes
# again — that is exactly the 2026-08-18 shape.
PEAK_RESIDENT_ROOM_BOUND = 32

ENGINE = "app.plugins.plugins['engram-vault-sync'].syncEngine"
SET_BLOCKED = ENGINE + ".setSyncBlocked({})"

# Fire-and-forget fullSync: the promise settles into window.__e2e77 instead of
# being awaited over CDP. Awaiting it made the CDP evaluate ceiling (120s) the
# real deadline, and a slow-but-progressing sync died as an unnamed CdpError.
KICK_SYNC = (
    "window.__e2e77 = {done: false}; " + ENGINE + ".fullSync().then("
    "r => { window.__e2e77 = {done: true, result: r}; }, "
    "e => { window.__e2e77 = {done: true, error: String(e)}; }); true"
)
SYNC_STATE = "JSON.stringify(window.__e2e77 || null)"


class _PeakResidencySampler:
    """Poll room residency on a background thread for the whole sync.

    Residency is a burst quantity (see residency_probe): the peak is only
    trustworthy if sampled continuously ACROSS the import. Sampling between
    fullSync passes did not do that — one pass usually carries the whole import,
    so the "running peak" was just a before/after pair. A thread also keeps the
    probe's docker-exec + rpc cost off the test's own control flow.
    """

    def __init__(self, interval_s: float = 1.0) -> None:
        self.peak = 0
        self._error: BaseException | None = None
        self._stop = threading.Event()
        self._interval = interval_s
        self._thread = threading.Thread(target=self._run, daemon=True)

    def _run(self) -> None:
        while True:
            try:
                self.peak = max(self.peak, read_resident_rooms())
            except BaseException as e:  # re-raised on the test thread by stop()
                self._error = e
                return
            if self._stop.wait(self._interval):
                return

    def start(self) -> "_PeakResidencySampler":
        self._thread.start()
        return self

    def abort(self) -> None:
        self._stop.set()

    def stop(self) -> int:
        """Take one final sample, stop, and return the peak (raises probe errors)."""
        self._stop.set()
        self._thread.join(timeout=30)
        if self._error is not None:
            raise AssertionError(f"residency probe failed mid-sync: {self._error!r}")
        self.peak = max(self.peak, read_resident_rooms())
        return self.peak


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


@pytest.mark.timeout(300)  # index wait (60s) + CONVERGE_DEADLINE_S + probes/cleanup
@pytest.mark.asyncio
async def test_bulk_first_sync_timing(vault_a, cdp_a, api_sync):
    sampler: _PeakResidencySampler | None = None
    try:
        # Arm BEFORE the gate work: the counters are cumulative per node and the
        # measured window is a delta, so arming early only widens what is
        # attributed to this test — it can never under-count the sync. Route
        # counts are Bulk/-scoped and re-armed (reset) here.
        arm_room_starts()
        rooms_before = read_room_starts()
        arm_routes("Bulk/")

        # Close the sync gate FIRST: every raw write below fires the vault
        # watcher, and an open gate turns that into 1,000 debounced single-note
        # auto-pushes — a request storm that exhausts the rate budget and
        # starves the batch sync this test measures. handleModify short-circuits
        # while the gate is closed.
        await cdp_a.evaluate(SET_BLOCKED.format("true"))

        # Seed 1,000 files on disk, then wait for Obsidian's indexer to see them
        # (raw filesystem writes only reach app.vault.getFiles() once the
        # watcher fires). A readiness gate, not part of any assertion.
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
            await asyncio.sleep(1)
        else:
            raise TimeoutError(f"Obsidian indexed only {count}/{NOTE_COUNT} bulk files")

        # Re-open the gate the same way a user accepting the PreSync modal does
        # (persists the fingerprint + flips syncBlocked false).
        await cdp_a.accept_sync_gate()

        # Drive the bulk first sync to server-side convergence. A single
        # fullSync()'s `pushed` count is an unreliable proxy under CI load
        # (issue #627): it returns {pulled:0, pushed:0} when the plugin's async
        # startup re-asserts syncBlocked after our unblock, and one call can
        # report a partial count while the remainder lands moments later. So the
        # SERVER manifest is the oracle, and a sync that settled short of it is
        # re-kicked (never stacked on an in-flight one).
        sampler = _PeakResidencySampler().start()
        started = time.monotonic()
        deadline = started + CONVERGE_DEADLINE_S
        bulk_count = 0
        kicks = 0
        last_state = None
        while time.monotonic() < deadline:
            raw = await cdp_a.evaluate(SYNC_STATE)
            last_state = json.loads(raw) if isinstance(raw, str) else None
            if last_state is None or last_state.get("done"):
                await cdp_a.evaluate(SET_BLOCKED.format("false"))
                await cdp_a.evaluate(KICK_SYNC)
                kicks += 1
            manifest = api_sync.get_manifest()
            bulk_count = sum(
                1 for n in manifest["notes"] if n["path"].startswith("Bulk/")
            )
            if bulk_count >= NOTE_COUNT:
                break
            await asyncio.sleep(2)
        elapsed = time.monotonic() - started
        peak_resident = sampler.stop()
        sampler = None

        # Informational only — a trend line, deliberately not asserted.
        print(
            f"\ntest_77 converged {bulk_count}/{NOTE_COUNT} in {elapsed:.1f}s "
            f"({kicks} fullSync kick(s), last={last_state})"
        )
        assert bulk_count >= NOTE_COUNT, (
            f"bulk first sync converged only {bulk_count}/{NOTE_COUNT} notes "
            f"within the {CONVERGE_DEADLINE_S}s hang deadline — the sync stalled "
            f"({kicks} fullSync kick(s), last={last_state})"
        )

        # The transport claim, load-invariant: every note came over crdt_create
        # and none as a per-note REST upsert. crdt_create >= N (not ==) because a
        # timed-out create is legitimately retried.
        routes = read_routes()
        print(f"\ntest_77 write routes for Bulk/: {routes}")
        assert routes.rest_upsert == 0, (
            f"{routes.rest_upsert} Bulk/ notes were written via per-note "
            f"POST /notes ({routes}) — the bulk first sync fell back to REST "
            "instead of socket-native crdt_create."
        )
        assert routes.crdt_create >= NOTE_COUNT, (
            f"only {routes.crdt_create} crdt_create frames for {NOTE_COUNT} Bulk/ "
            f"notes ({routes}) — the rest reached the server by some other path."
        )

        # Read AFTER convergence: a room allocated by the tail of the sync must
        # be counted, and the drain means residency would already have shed it.
        rooms = read_room_starts() - rooms_before
        print(f"\ntest_77 peak resident rooms: {peak_resident}")
        print(f"\ntest_77 rooms allocated for {NOTE_COUNT} notes: {rooms}")
        cold_rooms = rooms.edit + rooms.create_batch + rooms.unknown
        assert cold_rooms <= ROOM_ALLOC_BOUND, (
            f"bulk first sync of {NOTE_COUNT} notes allocated {rooms} — expected "
            f"<= {ROOM_ALLOC_BOUND} rooms from the crdt_msg paths (#1409: rooms "
            "are for notes open in an editor, not for imported files). The "
            "per-source split names the path that regressed; `unknown` means an "
            "allocation site shipped without a source tag."
        )
        assert peak_resident <= PEAK_RESIDENT_ROOM_BOUND, (
            f"peak {peak_resident} CONCURRENT rooms during the import, past the "
            f"{PEAK_RESIDENT_ROOM_BOUND} bound. This is the memory-shaped half of "
            "#1409 (2026-08-18: ~2000 resident rooms, 757 -> 2744 processes). A "
            "note room exits on auto_exit when its last observer leaves, so a "
            "climb here means something is enrolling — and holding — idle notes."
        )
        assert rooms.handshake <= HANDSHAKE_ROOM_RATCHET, (
            f"enrolment opened {rooms.handshake} handshake rooms for "
            f"{NOTE_COUNT} notes, past the {HANDSHAKE_ROOM_RATCHET} ratchet. This "
            "is #1409's open half — the ratchet only fails when it gets WORSE."
        )
    finally:
        if sampler is not None:  # failed mid-sync: stop the thread, keep the real error
            sampler.abort()
        await _cleanup_bulk_residue(vault_a, cdp_a, api_sync)
