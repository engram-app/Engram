"""Run Elixir expressions inside the CI backend container via the release's
`bin/engram rpc` (same docker-exec pattern as crypto_probe's psql probe).

Used to stage server-side states a client API cannot reach — e.g. killing a
CRDT room out from under a connected observer, or flipping a runtime rate
limit — so failure modes that are timing-dependent in production become
deterministic in a test.
"""

from __future__ import annotations

import os
import subprocess

CI_ENGRAM_CONTAINER = os.environ.get("CI_ENGRAM_CONTAINER", "engram-engram-1")


def backend_rpc(expr: str, timeout: int = 20) -> str:
    """Evaluate `expr` on the running backend node; returns stdout.

    Raises on a non-zero exit so a mis-staged test fails loudly at the stage
    step instead of producing a misleading assertion failure later.
    """
    result = subprocess.run(
        ["docker", "exec", "-i", CI_ENGRAM_CONTAINER, "/app/bin/engram", "rpc", expr],
        capture_output=True,
        text=True,
        timeout=timeout,
    )
    if result.returncode != 0:
        raise RuntimeError(f"backend_rpc({expr!r}) failed: {result.stderr.strip()}")
    return result.stdout.strip()


def vault_user_expr(vault_id: str) -> str:
    """Elixir statements binding `u` to the owner of `vault_id` (one logical
    line, ends in `; `). Shared by the probes that decrypt a vault's notes."""
    return (
        f'{{:ok, vb}} = Ecto.UUID.dump("{vault_id}"); '
        "{:ok, vr} = Ecto.Adapters.SQL.query(Engram.Repo, "
        '"select user_id::text from vaults where id=$1", [vb]); '
        "u = Engram.Accounts.get_user!(hd(hd(vr.rows))); "
    )


# Binds `load_doc.(note, user)`: a note's server Y.Doc the way a room's bind
# builds it (decrypted snapshot plus the update tail after it), WITHOUT
# `normalize_doc`, so reading never heals what it reads. The tail matters: a
# second lineage can live only in the tail until the debounced checkpoint
# folds it in. `note` must carry `id`, `vault_id` and the body fields
# (`NoteBody.select_note`); call inside `Repo.with_tenant` (the tail is RLS).
LOAD_DOC_EXPR = (
    "load_doc = fn n, u -> "
    "{:ok, st} = Engram.Crypto.decrypt_crdt_state(n, u); "
    "{:ok, d} = Engram.Notes.CrdtBridge.doc_from_state(st); "
    "Engram.Notes.CrdtPersistence.replay_tail(d, u, n.id, n.vault_id); d end; "
)
