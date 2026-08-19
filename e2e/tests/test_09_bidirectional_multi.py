"""Test 09: A creates 3 files, B creates 3 files → both vaults end up with all 6."""

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.log_oracle import wait_for_delivery
from helpers.vault import read_note, write_note

# Live count of CRDT room actors on the backend node. `:global` is the
# authoritative registry CrdtRegistry.lookup/1 reads; CrdtRoomLru.resident_count/0
# is deliberately NOT used here because it lags until the next sweep.
_ROOM_COUNT_EXPR = (
    ":global.registered_names() |> Enum.count(&match?({:crdt_doc, _}, &1)) |> IO.puts()"
)


def _room_count() -> int:
    return int(backend_rpc(_ROOM_COUNT_EXPR).strip().splitlines()[-1])


@pytest.mark.asyncio
async def test_bidirectional_multi_file(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Both sides create multiple files; after live sync, both vaults have all of them."""
    rooms_before = _room_count()

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
    # Asserted as a DELTA, not an absolute: the e2e stack is one shared backend
    # node, so a concurrently-live room from another test would make an absolute
    # bound flaky. The tolerance covers a live-bound editor room on either
    # device; it is deliberately far below the 6 that a room-per-note path would
    # produce, so this fails loudly if the seed ever regresses to opening rooms.
    rooms_after = _room_count()
    delta = rooms_after - rooms_before
    assert delta <= 2, (
        f"creating {len(a_files) + len(b_files)} notes added {delta} CRDT rooms "
        f"({rooms_before} -> {rooms_after}); the detached genesis seed must not "
        "allocate a room per note"
    )
