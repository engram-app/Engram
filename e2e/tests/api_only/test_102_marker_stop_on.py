"""Test 102: on the prod-built e2e backend the S6 step 4 marker write stop is
ON (Engram#2523, release E): a folder create writes no `kind = 'folder'`
marker row and the folder is still listed (from `folders.explicit`).

The unit suite keeps the marker path by default (`config/test.exs` sets
`folder_marker_stop` false); this test is what proves prod's stop-on path
runs in e2e, on the real rollback floor (release D) and the real ledgers.
API-only.
"""

from __future__ import annotations

import time
import uuid

from helpers.backend_rpc import backend_rpc, vault_user_expr
from helpers.folder_ops import _bool_rpc, _lines

# One rpc, scoped to THIS test's folder (the e2e vault is shared by ~110
# tests, so a vault-wide count is not a signal): live markers at the
# folder's path hash or with its row's id (a marker keeps its folder row's
# UUID), and the folder row's explicit flag.
_PROBE = (
    "{:ok, fk} = Engram.Crypto.dek_filter_key(u); "
    'h = Engram.Folders.Rows.path_hmac(fk, "FOLDER"); '
    "r = Engram.Repo.with_tenant!(u.id, fn -> "
    '[id] = Engram.Folders.Rows.ids_at(u, "VAULT", ["FOLDER"]); '
    "{:ok, m} = Ecto.Adapters.SQL.query(Engram.Repo, "
    "\"select count(*) from notes where vault_id = $1 and kind = 'folder' "
    'and deleted_at is null and (folder_hmac = $2 or id = $3)", '
    "[vb, h, Ecto.UUID.dump!(id)]); "
    "{:ok, f} = Ecto.Adapters.SQL.query(Engram.Repo, "
    '"select explicit from folders where id = $1 and deleted_at is null", '
    "[Ecto.UUID.dump!(id)]); "
    "{hd(hd(m.rows)), f.rows} end); "
    'IO.puts("probe=#{inspect(r)}")'
)


# {kill switch, rollback floor leg, explicit reads, FolderTable completed_at}
_LEGS = (
    "{Engram.ServiceConfig.get(:folder_marker_stop, true), "
    "Engram.Folders.MarkerStop.floors?(), Engram.Folders.Rows.explicit_reads?(), "
    "Engram.DataMigrations.completed_at(Engram.DataMigrations.FolderTable.name(), "
    "Engram.DataMigrations.FolderTable.version())}"
)


class TestMarkerStopOn:
    def test_folder_create_writes_no_marker_row(self, api_sync):
        # The stop's legs settle at boot: the @reboot data-migration runner
        # closes the FolderTable ledger, and `Rows.explicit_reads?/0` caches
        # its read for up to a minute. Run 44673881139 hit that window (ledger
        # done 04:24:03, this test 04:24:09), so wait past the cache.
        deadline = time.monotonic() + 90
        while not _bool_rpc("marker_stop", "Engram.Folders.MarkerStop.on?()"):
            if time.monotonic() > deadline:
                legs = backend_rpc(f'IO.puts("legs=#{{inspect({_LEGS})}}")')
                raise AssertionError(
                    "MarkerStop.on?() never read true on the e2e backend, so the "
                    f"stop-on path is not covered: {legs}"
                )
            time.sleep(2)

        vaults = api_sync.list_vaults()
        assert vaults, "api_sync should have a registered vault"
        vault_id = vaults[0]["id"]
        client = api_sync.with_vault(vault_id)

        folder = f"marker-stop-{uuid.uuid4().hex}"
        assert client.create_folder(folder) in (200, 201)

        expr = vault_user_expr(vault_id) + _PROBE.replace("FOLDER", folder).replace(
            "VAULT", vault_id
        )
        lines = _lines(backend_rpc(expr))
        assert "probe={0, [[true]]}" in lines, (
            f"want no live marker for {folder} and its row explicit, got {lines}"
        )

        resp = client.session.get(f"{client.base_url}/folders/explicit", timeout=10)
        assert resp.status_code == 200
        assert folder in {f["name"] for f in resp.json()["folders"]}
