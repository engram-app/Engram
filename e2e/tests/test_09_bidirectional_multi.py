"""Test 09: A creates 3 files, B creates 3 files → both vaults end up with all 6."""

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.log_oracle import wait_for_delivery
from helpers.vault import read_note, write_note

# Cumulative count of CRDT rooms ALLOCATED on the backend node, via the
# [:engram, :crdt, :room_start] telemetry event CrdtDoc.start_link/1 emits once
# per room process actually created.
#
# Residency is NOT usable for this: ci/compose.yml sets CRDT_IDLE_EXIT_MS=5000,
# so rooms a regression opened at the top of a test have drained long before the
# test ends. Sampling `:global` afterwards measures instantaneous residency, and
# a full room-per-note regression passes that assertion — the burst comes and
# goes entirely between two samples. Allocation is the claim; count allocation.
#
# The counter lives in :persistent_term (an :atomics ref, the same idiom
# FanoutPacer.test_drop_next/2 uses for e2e-armed counters) so it survives the
# rpc process that arms it.
# Kept to ONE logical Elixir line: `bin/engram rpc` takes the expression as a
# single argv, and a one-liner cannot be reshaped by any newline handling on the
# way through the release wrapper.
_ARM_EXPR = (
    ":persistent_term.put(:e2e_room_starts, :counters.new(1, [])); "
    ':telemetry.detach("e2e-room-starts"); '
    ':telemetry.attach("e2e-room-starts", [:engram, :crdt, :room_start], '
    "fn _, _, _, _ -> "
    ":counters.add(:persistent_term.get(:e2e_room_starts), 1, 1) "
    "end, nil); "
    'IO.puts("armed")'
)

_READ_EXPR = ":counters.get(:persistent_term.get(:e2e_room_starts), 1) |> IO.puts()"


def _arm_room_start_counter() -> None:
    # backend_rpc raises on a non-zero exit, and this asserts the sentinel, so a
    # mis-staged probe fails loudly here rather than leaving a vacuously green
    # assertion at the end of the test.
    out = backend_rpc(_ARM_EXPR)
    assert "armed" in out, f"room-start counter did not arm: {out!r}"


def _rooms_allocated() -> int:
    return int(backend_rpc(_READ_EXPR).strip().splitlines()[-1])


@pytest.mark.asyncio
async def test_bidirectional_multi_file(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides create multiple files; after live sync, both vaults have all of them."""
    _arm_room_start_counter()
    rooms_before = _rooms_allocated()

    a_files = {
        "E2E/Multi/FromA-1.md": "# From A 1\nFirst file from A",
        "E2E/Multi/FromA-2.md": "# From A 2\nSecond file from A",
        "E2E/Multi/FromA-3.md": "# From A 3\nThird file from A",
    }
    b_files = {
        "E2E/Multi/FromB-1.md": "# From B 1\nFirst file from B",
        "E2E/Multi/FromB-2.md": "# From B 2\nSecond file from B",
        "E2E/Multi/FromB-3.md": "# From B 3\nThird file from B",
    }

    # A creates its files
    for path, content in a_files.items():
        write_note(vault_a, path, content)

    # B creates its files
    for path, content in b_files.items():
        write_note(vault_b, path, content)

    # Wait for all 6 files to land on server
    for path in list(a_files) + list(b_files):
        api_sync.wait_for_note(path)

    # A receives B's files live, B receives A's files live — no manual pull.
    for path in b_files:
        wait_for_delivery(vault_a, path, api_sync)
    for path in a_files:
        wait_for_delivery(vault_b, path, api_sync)

    # Verify A has all 6 files
    for path in list(a_files) + list(b_files):
        content = read_note(vault_a, path)
        assert content, f"A missing {path}"

    # Verify B has all 6 files
    for path in list(a_files) + list(b_files):
        content = read_note(vault_b, path)
        assert content, f"B missing {path}"

    # Verify content integrity
    for path, expected in {**a_files, **b_files}.items():
        a_content = read_note(vault_a, path)
        b_content = read_note(vault_b, path)
        heading = expected.split("\n")[0]
        assert heading in a_content, f"A's {path} missing heading"
        assert heading in b_content, f"B's {path} missing heading"

    # The headline claim of the detached genesis seed (#1409): creating notes
    # must not allocate one SharedDoc room per note. Six notes were created and
    # delivered to the other device here; before the seed each of those bodies
    # arrived as a crdt_msg, which spun a room per note on the way in.
    #
    # Asserted as a DELTA over this window, not an absolute: the suite runs
    # under xdist, so a sibling worker's rooms land in the same node-wide
    # counter. The bound is therefore stated against the thing a regression
    # would do — allocate at least one room PER NOTE — rather than against an
    # ideal of zero: fewer than `n_files` allocations cannot be produced by a
    # room-per-note path, while a sibling test would have to start six rooms
    # inside this window to false-fail it, and e2e tests create one or two notes
    # each. Ideal is 0; if this ever sits just under the bound, that is a real
    # signal worth chasing rather than slack to absorb.
    n_files = len(a_files) + len(b_files)
    rooms_after = _rooms_allocated()
    allocated = rooms_after - rooms_before
    assert allocated < n_files, (
        f"creating {n_files} notes allocated {allocated} CRDT rooms "
        f"({rooms_before} -> {rooms_after}); the detached genesis seed must not "
        "allocate a room per note"
    )
