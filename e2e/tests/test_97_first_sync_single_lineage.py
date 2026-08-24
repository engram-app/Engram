"""Test 97: a first sync must leave ONE Yjs lineage per note, not two.

The 2026-08-23 defect. A real vault ("health local test v10", 316 notes) synced
into a fresh server vault and every stored note came out holding TWO Yjs
clients, each with a clock equal to half the final character count — the whole
document inserted twice, once per client. Server bytes were exactly 2x the file
on disk. Disk was never wrong.

Three properties made it nearly invisible, and each one is why this test is
shaped the way it is:

  * Opening a note converged it back to 1x. `Visit Notes Log (Revere Health).md`
    went 67,630 -> 33,833 bytes the moment it was viewed in the web app, so
    anything a human inspects has already healed by the time they look.
  * The two insertions do not always land end-to-end. Where they interleaved the
    text was still 2x but not a clean `X+X`, so a "first half == second half"
    check reported 17 of 60 doubled when the true answer was 224 of 316.
  * The plugin reported success. Note count, room count and seed outcomes were
    all exactly as expected; only the doc STRUCTURE was wrong.

So the assertion is structural — count lineages, not bytes, and read it from the
server rather than from any client that could have healed it. `lineage_probe`
carries the rationale for reading the state vector's leading varint.

Deliberately small (40 notes): this pins a correctness property that reproduced
at 100% of notes, not a throughput bound. test_77 owns the bulk-timing bound and
its 1,000-note fixture, which cannot run inside the 120s CDP evaluate cap on a
loaded dev box (see docs/context/local-crdt-e2e-repro.md).

Scoped to this test's own path prefix (2026-08-24). The vault fixture is
session-scoped and shared by the whole suite, and a note legitimately edited by
two devices holds two Yjs clients — so an unscoped sample has a non-zero floor
this test can never drive to zero. See `helpers/lineage_probe`.
"""

from __future__ import annotations

import time
import uuid

import pytest

from helpers.lineage_probe import read_lineages
from helpers.room_probe import arm_room_starts, read_room_starts
from helpers.seed_probe import arm_seeds, read_seeds
from helpers.vault import write_note

NOTE_COUNT = 15
# Must stay well under pytest.ini's 180s timeout. Equal to it, the loop
# can never reach its own assertion — pytest-timeout kills the test first
# and reports a generic timeout instead of "converged only N/M".
CONVERGE_BOUND_S = 90

SET_BLOCKED = "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"


@pytest.mark.asyncio
async def test_first_sync_leaves_one_lineage_per_note(
    vault_a, cdp_a, api_sync, sync_vault_id
):
    run = uuid.uuid4().hex[:12]
    prefix = f"Lineage-{run}"

    # Close the gate before touching disk, for the same reason test_77 does: each
    # raw write fires the vault watcher, and an open gate turns 40 writes into 40
    # debounced single-note pushes, which is a DIFFERENT code path from the bulk
    # first sync this test is about.
    arm_room_starts()
    arm_seeds()
    rooms_before = read_room_starts()
    seeds_before = read_seeds()

    await cdp_a.evaluate(SET_BLOCKED.format("true"))

    # Sizes vary deliberately. The production sample doubled notes from 17 KB to
    # 68 KB, and a fixture of uniform tiny notes is exactly the shape that let
    # this ship — a small note's two lineages can merge into a single run and
    # hide the structure that a larger one exposes.
    # Frontmatter on purpose. The doubling has a frontmatter-only variant —
    # `hasHistory` is body-only, so a note with an empty body but existing
    # history reported false and got its ORDER_KEY doubled (sync.ts's
    # applyCrdtCreateAck comment). The first doubled note recovered from the
    # reporter's vault had its YAML block repeated inside ONE `---` fence, so a
    # body-only fixture cannot see that shape at all.
    for i in range(NOTE_COUNT):
        body = "\n".join(f"line {j} of note {i} in {run}" for j in range(i * 12 + 10))
        fm = f"---\ntags:\n  - lineage\n  - n{i}\nreviewed: 2026-08-23\n---\n\n"
        write_note(vault_a, f"{prefix}/N{i:03d}.md", f"{fm}# Note {i}\n\n{body}\n")

    deadline = time.monotonic() + 60
    indexed = 0
    while time.monotonic() < deadline:
        indexed = await cdp_a.evaluate(
            f"app.vault.getFiles().filter(f => f.path.startsWith('{prefix}/')).length"
        )
        if isinstance(indexed, int) and indexed >= NOTE_COUNT:
            break
        time.sleep(1)
    else:
        raise TimeoutError(f"Obsidian indexed only {indexed}/{NOTE_COUNT} files")

    await cdp_a.accept_sync_gate()

    started = time.monotonic()
    deadline = started + CONVERGE_BOUND_S
    landed = 0
    while time.monotonic() < deadline:
        await cdp_a.evaluate(SET_BLOCKED.format("false"))
        await cdp_a.trigger_full_sync()
        manifest = api_sync.get_manifest()
        landed = sum(1 for n in manifest["notes"] if n["path"].startswith(prefix))
        if landed >= NOTE_COUNT:
            break
        time.sleep(2)

    assert landed >= NOTE_COUNT, (
        f"only {landed}/{NOTE_COUNT} notes converged in "
        f"{time.monotonic() - started:.1f}s — the lineage assertion below would "
        "be measuring a partial sync"
    )

    # Read from the SERVER. A client-side read would be answered by the very doc
    # whose lineage is in question, and viewing a note is what heals it.
    lineages = read_lineages(sync_vault_id, prefix)
    # Printed, and the note total asserted, because `multi_client == 0` is
    # satisfied vacuously by an empty vault.
    # Room split alongside the lineage count. The production run that corrupted
    # showed 213 edit-class rooms for 316 notes — one cold `crdt_msg` per note on
    # top of the roomless genesis seeds. That cold send is the suspected carrier
    # of the second lineage, so if this run shows edit=0 the scenario is missing
    # the precondition rather than the defect being fixed.
    rooms = read_room_starts() - rooms_before
    seeds = read_seeds() - seeds_before
    print(f"\ntest_97 {lineages} | rooms: {rooms} | {seeds}")
    assert lineages.notes >= NOTE_COUNT, (
        f"server holds only {lineages.notes} notes — the lineage assertion "
        "below would pass vacuously"
    )

    assert lineages.multi_client == 0, (
        f"first sync produced {lineages}. Two lineages on one note means the "
        "device never adopted the genesis lineage the server stored and later "
        "shipped its own disk-seeded copy as a second full insertion — the "
        "server then holds the document twice while disk holds it once. See "
        "sync.ts applyCrdtCreateAck's genesis-adopt guard."
    )
