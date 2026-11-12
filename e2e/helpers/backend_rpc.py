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
