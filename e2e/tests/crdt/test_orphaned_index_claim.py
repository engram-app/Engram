"""An index claim the server cannot honour must repair itself, not strand the note.

`getOrMint` publishes a `filemeta_v0` claim the moment it mints, without waiting
for `crdt_create` to be acked. When the create fails to land, three sources of
identity disagree and stay that way:

  * the index claims `path -> note_id`
  * no `notes` row exists for that id
  * the file is still on disk

The note then lives on exactly ONE device. Every `crdt_msg` for it is dropped
`note_not_found`, and `ProjectVaultIndex` retries the unresolvable entry forever
— `applied=0 unresolved=N` for that whole vault, permanently, which also pins
the only signal we have for index/row disagreement.

Measured in prod on 2026-09-01 (engram-app/engram#1550): six ids took
`note_not_found` in one 8-minute window on one vault. Four healed. The two whose
claim had already landed stayed stranded for 16+ hours with no user-visible
signal, because `ensureNoteIdMapped` early-returns on `pathForId !== null` and
for an orphan the mapping IS the claim — the id vouches for itself.

The plugin fix (Engram-obsidian#497) re-drives the create from the
`note_not_found` reply. Its unit tests assert the create is ENQUEUED. This
asserts the thing that actually matters and that no unit test can: the stranded
note reaches the server, under the same id, and the vault's index converges
again.

Refs engram-app/engram#1550, engram-app/Engram-obsidian#497.
"""

from __future__ import annotations

import os
import time
import uuid

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.latency import DELIVERY_TIMEOUT
from helpers.vault import write_note

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = DELIVERY_TIMEOUT
FILEMETA = "filemeta_v0"


def _index_paths(vault_id: str) -> list[str]:
    """Paths claimed in `vault_id`'s `filemeta_v0`.

    Same `load_doc/2` recipe `test_index_crdt_client_writes.py` uses, and for
    the same reason: it is what `bind/3` reads, so a claim that only reached the
    tail log still counts and the test does not hinge on checkpoint timing.
    """
    out = backend_rpc(
        f'%{{rows: [[uid]]}} = Engram.Repo.query!("select user_id from vaults where id = $1", '
        f'[Ecto.UUID.dump!("{vault_id}")]); '
        "u = Engram.Repo.get(Engram.Accounts.User, Ecto.UUID.load!(uid)); "
        f'{{:ok, doc}} = Engram.Notes.CrdtIndexPersistence.load_doc(u, "{vault_id}"); '
        f'doc |> Yex.Doc.get_map("{FILEMETA}") |> Yex.Map.to_map() '
        '|> Map.keys() |> Enum.join("\\n") |> IO.puts()'
    )
    return [line.strip() for line in out.splitlines() if line.strip()]


def _delete_row_leaving_the_claim(vault_id: str, note_id: str) -> None:
    """Delete the `notes` row by raw SQL, leaving `filemeta_v0` untouched.

    Deliberately NOT `Notes.delete_note_by_id/4`: that is the well-behaved path
    — it tombstones the id and releases the index claim, which is the state we
    are trying NOT to construct. The orphan is a row that is simply absent while
    the claim survives, and raw SQL is the only way to reach it from outside.

    Wrapped in `with_tenant/2` because `notes` is RLS-guarded; the raw query is
    not rewritten by `prepare_query/3`, so the tenant context has to be set
    explicitly rather than inherited.
    """
    backend_rpc(
        f'%{{rows: [[uid]]}} = Engram.Repo.query!("select user_id from vaults where id = $1", '
        f'[Ecto.UUID.dump!("{vault_id}")]); '
        "user_id = Ecto.UUID.load!(uid); "
        "Engram.Repo.with_tenant(user_id, fn -> "
        f'Engram.Repo.query!("delete from notes where id = $1", [Ecto.UUID.dump!("{note_id}")]) '
        "end); "
        "IO.puts(:ok)"
    )


def _row_exists(note_id: str) -> bool:
    out = backend_rpc(
        f'%{{rows: rows}} = Engram.Repo.query!("select count(*) from notes where id = $1", '
        f'[Ecto.UUID.dump!("{note_id}")]); '
        "rows |> hd() |> hd() |> Integer.to_string() |> IO.puts()"
    )
    return out.strip().endswith("1")


def _wait_for_row(note_id: str, present: bool, timeout: int = CRDT_TIMEOUT) -> None:
    deadline = time.time() + timeout
    while time.time() < deadline:
        if _row_exists(note_id) == present:
            return
        time.sleep(1)
    verb = "reappear" if present else "go away"
    raise AssertionError(f"note row {note_id} did not {verb} within {timeout}s")


@pytest.mark.asyncio
async def test_an_orphaned_claim_re_creates_the_note_under_the_same_id(
    vault_a, cdp_a, api_sync, sync_vault_id
):
    """[P0] A claim with no row behind it recovers the note instead of stranding it."""
    suffix = uuid.uuid4().hex[:12]
    path = f"E2E/Crdt/Orphan-{suffix}.md"
    body = f"# Orphan {suffix}\nThis note must not be stranded on one device.\n"

    # 1. An ordinary, healthy note: row on the server, claim in the index.
    write_note(vault_a, path, body)
    note = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = note.get("note", note) if isinstance(note, dict) else {}
    note_id = str(inner.get("id") or inner.get("note_id") or "")
    assert note_id, f"no note id in GET /notes/{path}: {note}"

    deadline = time.time() + CRDT_TIMEOUT
    while time.time() < deadline and path not in _index_paths(sync_vault_id):
        time.sleep(1)
    assert path in _index_paths(sync_vault_id), (
        f"precondition failed: the client never claimed {path!r} in the server index, "
        "so there is no claim to orphan and the assertions below would be vacuous"
    )

    # 2. Construct the orphan. Two halves, because either alone is a DIFFERENT
    #    and already-handled state:
    #
    #    (a) the row goes away while the claim stays — the server side.
    #    (b) the client forgets `crdtHead` for the path — the client side.
    #
    #    (b) matters and is easy to get wrong. A real orphan never had a
    #    create-ack, so `crdtHead` was never written; deleting only the row
    #    would leave the client believing `hasServerNote`, which is the state
    #    after a REMOTE DELETE, not after a lost create. Skipping this makes the
    #    test construct something the fix deliberately does not touch, and it
    #    would then fail for the wrong reason.
    _delete_row_leaving_the_claim(sync_vault_id, note_id)
    _wait_for_row(note_id, present=False)

    forgot = await cdp_a.evaluate(
        """
        (() => {
          const eng = app.plugins.plugins["engram-vault-sync"].syncEngine;
          const row = eng.syncState.get(%r);
          if (!row) return "no-row";
          delete row.crdtHead;
          return eng.syncState.get(%r)?.crdtHead ?? "cleared";
        })()
        """
        % (path, path)
    )
    assert forgot == "cleared", (
        f"could not clear the client's crdtHead for {path}: {forgot!r}"
    )

    assert path in _index_paths(sync_vault_id), (
        "the claim must survive the row delete — without it this is an ordinary "
        "missing note, not the orphan class under test"
    )

    # 3. THE TRIGGER. The repair fires on the `note_not_found` reply, and
    #    `canSendLive` holds ordinary ops behind `hasServerNote` — so what has to
    #    escape is a HANDSHAKE, which means the note must be enrolled. Opening it
    #    in the editor live-binds the doc and does exactly that. (In the prod
    #    case the same STEP1 came from `reEnrollUnsent` on reconnect.)
    opened = await cdp_a.evaluate(
        """
        (async () => {
          const f = app.vault.getAbstractFileByPath(%r);
          if (!f) return "no-file";
          await app.workspace.getLeaf(false).openFile(f);
          return app.workspace.activeEditor?.file?.path ?? "no-active";
        })()
        """
        % path,
        await_promise=True,
    )
    assert opened == path, f"failed to live-bind the note in Obsidian: {opened!r}"

    # 4. The note comes back, under the SAME id. A fresh mint would also make the
    #    note reappear, which is why this asserts the id and not just presence:
    #    re-minting strands the local Y.Doc holding the user's content and leaves
    #    a second claim behind.
    _wait_for_row(note_id, present=True)
    recovered = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = recovered.get("note", recovered) if isinstance(recovered, dict) else {}
    assert str(inner.get("id") or inner.get("note_id")) == note_id, (
        "the note came back under a DIFFERENT id — the local doc keyed by the "
        "original id is now stranded and the index holds two claims"
    )

    # 5. And the index agrees again, which is the condition whose absence pinned
    #    `unresolved` non-zero for the whole vault.
    assert path in _index_paths(sync_vault_id)
