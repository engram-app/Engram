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

from helpers.crypto_probe import psql_one
from helpers.folder_ops import _bool_rpc


class TestMarkerStopOn:
    def test_folder_create_writes_no_marker_row(self, api_sync):
        assert _bool_rpc("marker_stop", "Engram.Folders.MarkerStop.on?()"), (
            "MarkerStop.on?() is false on the e2e backend: the stop-on path is not covered"
        )

        vaults = api_sync.list_vaults()
        assert vaults, "api_sync should have a registered vault"
        vault_id = vaults[0]["id"]
        client = api_sync.with_vault(vault_id)

        before = int(
            psql_one(
                f"SELECT count(*) FROM notes WHERE vault_id = '{vault_id}' AND kind = 'folder';",
                "marker count before",
            )
        )
        folder = f"marker-stop-{int(time.time())}"
        assert client.create_folder(folder) in (200, 201)

        after = int(
            psql_one(
                f"SELECT count(*) FROM notes WHERE vault_id = '{vault_id}' AND kind = 'folder';",
                "marker count after",
            )
        )
        assert after == before, f"a folder create wrote {after - before} marker row(s)"

        resp = client.session.get(f"{client.base_url}/folders/explicit", timeout=10)
        assert resp.status_code == 200
        assert folder in {f["name"] for f in resp.json()["folders"]}
