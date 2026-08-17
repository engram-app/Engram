"""The plugin writes `filemeta_v0`, and the SERVER sees it.

This is the test the whole index-CRDT effort was missing, and its absence is
why a write-only client shipped through three green CI runs: every existing
test has our client on both ends. The plugin's unit tests wire two client
rooms to each other, and the backend's end-to-end test drives a synthetic
client through the real channel. Neither has ever asked whether the plugin's
frames are something the server accepts.

So this asserts the one thing nothing else does: a rename performed in a real
Obsidian vault reaches the real backend and lands in the vault's authoritative
index. If the wire format, the event name, the join_ref discipline or the
handshake is wrong in either direction, this is the test that says so.

Engram-obsidian#362 / engram-app/Engram#1146.
"""

import uuid

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.log_oracle import wait_for_delivery
from helpers.vault import write_note

# The index doc's map name. Matches the server (`CrdtIndexDoc.map_name/0`),
# Relay's `SyncStore.ts:20`, and the plugin's `FILEMETA_MAP` — a mismatch here
# syncs an empty doc forever without erroring, so it is asserted literally.
FILEMETA = "filemeta_v0"

# The index room checkpoints on exit and the client publishes on a microtask,
# so allow the same generous budget the other CRDT tests use rather than
# racing the settle.
INDEX_TIMEOUT = 45


def _index_paths(vault_id: str) -> list[str]:
    """Read the paths claimed in `vault_id`'s `filemeta_v0`.

    Goes through `load_doc/2` rather than the raw row on purpose: that is the
    same snapshot+tail recipe `bind/3` uses, so a claim that only reached the
    tail log (no checkpoint yet) still counts. Reading the snapshot alone would
    make this test pass or fail on checkpoint timing instead of on delivery.

    The vault lookup is raw SQL, not Ecto: `vaults` is one of `Repo`'s
    `@tenant_tables`, so an Ecto query outside `with_tenant/2` trips the
    tenant guard and raises. Raw SQL is not rewritten by `prepare_query/3`, and
    resolving user_id is the ONLY thing needed before `load_doc/2` — which
    establishes tenant context itself. Vault names are encrypted
    (`name_ciphertext`), so id is the only usable handle from the test side.
    """
    out = backend_rpc(
        f'%{{rows: [[uid]]}} = Engram.Repo.query!("select user_id from vaults where id = $1", [Ecto.UUID.dump!("{vault_id}")]); '
        "u = Engram.Repo.get(Engram.Accounts.User, Ecto.UUID.load!(uid)); "
        f'{{:ok, doc}} = Engram.Notes.CrdtIndexPersistence.load_doc(u, "{vault_id}"); '
        f'doc |> Yex.Doc.get_map("{FILEMETA}") |> Yex.Map.to_map() '
        '|> Map.keys() |> Enum.join("\\n") |> IO.puts()'
    )
    return [line.strip() for line in out.splitlines() if line.strip()]


def _wait_for_index(
    vault_id: str, path: str, present: bool, timeout: int = INDEX_TIMEOUT
) -> list[str]:
    import time

    deadline = time.time() + timeout
    paths: list[str] = []
    while time.time() < deadline:
        paths = _index_paths(vault_id)
        if (path in paths) == present:
            return paths
        time.sleep(1)
    verb = "appear in" if present else "leave"
    raise AssertionError(
        f"{path!r} did not {verb} the server index within {timeout}s. "
        f"Index currently claims: {paths!r}"
    )


@pytest.mark.asyncio
async def test_client_rename_reaches_the_server_index(
    vault_a, vault_b, cdp_a, api_sync, sync_vault_id
):
    """A rename in a real vault lands in the server's authoritative index."""
    # Unique per run: the A/B instances are session-scoped and not reset between
    # reruns, so a fixed path lets a prior attempt's note_id map contaminate the
    # next one. Old/new share a suffix so the rename maps them as a pair.
    suffix = uuid.uuid4().hex[:12]
    old_path = f"E2E/IndexOld-{suffix}.md"
    new_path = f"E2E/IndexNew-{suffix}.md"

    write_note(vault_a, old_path, "# Index CRDT\nThe client should claim this path.")
    api_sync.wait_for_note(old_path)
    wait_for_delivery(vault_b, old_path, api_sync)

    # The claim for the ORIGINAL path has to arrive before the rename means
    # anything: if the client never published, the rename below has nothing to
    # move and the assertion after it would pass vacuously on an empty index.
    _wait_for_index(sync_vault_id, old_path, present=True)

    # Obsidian's own rename event — the path the plugin's handleRename hooks.
    await cdp_a.rename_file(old_path, new_path)

    # The move, in the index the server treats as authoritative for paths.
    paths = _wait_for_index(sync_vault_id, new_path, present=True)
    assert new_path in paths

    # And the old claim is released, not left behind. A stale entry is not
    # cosmetic here: `ProjectVaultIndex` walks the entries and repaths the row
    # each one names, so two paths claiming one note is how a rename gets
    # dragged back.
    _wait_for_index(sync_vault_id, old_path, present=False)


@pytest.mark.asyncio
async def test_a_created_note_is_claimed_in_the_server_index(vault_a, api_sync, sync_vault_id):
    """A plain create reaches the index too, not just a rename.

    Creates are the volume case — `main.ts`'s cold-start loop resolve-or-mints
    an id for every markdown file — so if the handshake or the wire format is
    wrong this fails on the simplest possible path.
    """
    suffix = uuid.uuid4().hex[:12]
    path = f"E2E/IndexCreate-{suffix}.md"

    write_note(vault_a, path, "# Created\nClaimed on create.")
    api_sync.wait_for_note(path)

    paths = _wait_for_index(sync_vault_id, path, present=True)
    assert path in paths, f"the client never claimed {path!r} in the server index"
