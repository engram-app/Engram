"""Database + Qdrant probes for at-rest encryption assertions.

Used by E2E tests that need to verify ciphertext is actually at rest
(not just that the API returns plaintext). Mirrors the docker-exec psql
pattern from cleanup.py.

Phase B.4: toggle helpers (`wait_for_encryption_status`, `backdate_*`,
`set_user_cooldown_days`, `assert_note_plaintext_at_rest`) and the
plaintext-path probes (`_fetch_note_row`, `_fetch_attachment_row`,
`assert_note_ciphertext_at_rest`, `assert_attachment_ciphertext_at_rest`)
were retired with the encryption toggle. The Qdrant probes match the
v5 payload (`v5_path_id/1`, `v5_uuid/1`); a v5 point carries no text, so the
payload-ciphertext probe went with the legacy writer. To restore plaintext-path → row probes, add a release rpc
that translates the path under the user's filter_key and fetches by
path_hmac.
"""

from __future__ import annotations

import base64
import logging
import os
import re
import subprocess
import time

import requests

logger = logging.getLogger(__name__)

QDRANT_URL = os.environ.get("QDRANT_URL", "http://10.0.20.201:6333")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ci_test_notes")
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")

_UUID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")


def latest_note_path_hmac(vault_id: str) -> str:
    """Return base64(path_hmac) of the most-recently-created note in `vault_id`.

    #590: Qdrant payloads no longer carry plaintext `source_path`, so tests
    locate a note's points by its non-sensitive `path_hmac` — read straight
    from the encrypted `notes` row here (the backend already HMAC'd the path
    at insert under the user's filter_key; `encode(path_hmac,'base64')` in PG
    matches `Base.encode64/1` in the Qdrant payload).

    Call immediately after seeding a note (before seeding the next) so the
    `created_at DESC` ordering unambiguously identifies it.
    """
    if not _UUID_RE.match(vault_id):
        raise ValueError(f"Unsafe vault_id rejected: {vault_id!r}")

    # id is a UUIDv7 (time-ordered) so it breaks same-second created_at ties —
    # the row with the greatest id is the most recently minted.
    sql = (
        "SELECT encode(path_hmac, 'base64') FROM notes "
        f"WHERE vault_id = '{vault_id}' AND kind = 'note' "
        "ORDER BY created_at DESC, id DESC LIMIT 1;"
    )
    result = subprocess.run(
        ["docker", "exec", "-i", CI_POSTGRES_CONTAINER,
         "psql", "-U", "engram", "-d", "engram", "-tA", "-c", sql],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(
            f"latest_note_path_hmac({vault_id}) failed: {result.stderr.strip()}"
        )
    val = result.stdout.strip()
    if not val:
        raise RuntimeError(
            f"latest_note_path_hmac({vault_id}): no note row found in vault"
        )
    return val


def v5_path_id(path_hmac_b64: str) -> str:
    """The v5 payload's path id (`p`) for a base64 path HMAC: its first 128
    bits as 32 lowercase hex digits (`Engram.Vector.FilterId.from_hmac/1`)."""
    return base64.b64decode(path_hmac_b64)[:16].hex()


def v5_uuid(id_: str) -> str:
    """A user or vault id as the v5 payload stores it (`FilterId.uuid/1`)."""
    return str(id_).replace("-", "")


_B64_RE = re.compile(r"[A-Za-z0-9+/=]+")
_ALIVE_STATES = {"available", "scheduled", "executing", "retryable"}
_DEAD_STATES = {"discarded", "cancelled"}


def _qdrant_has_point(vault_id: str, path_hmac_b64: str) -> bool:
    try:
        resp = requests.post(
            f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
            json={
                # Every point is written in the v5 layout: short keys, ids
                # as 32 hex digits.
                "filter": {
                    "must": [
                        {"key": "v", "match": {"value": v5_uuid(vault_id)}},
                        {"key": "p", "match": {"value": v5_path_id(path_hmac_b64)}},
                    ]
                },
                "limit": 1,
                "with_payload": False,
                "with_vector": False,
            },
            timeout=5,
        )
        return bool(resp.ok and resp.json()["result"]["points"])
    except (requests.ConnectionError, requests.Timeout, KeyError):
        return False


def _embed_job_state(vault_id: str, path_hmac_b64: str) -> tuple[str | None, str]:
    """(state, errors_text) of the newest EmbedNote job for the note, or (None, "")."""
    if not _UUID_RE.match(vault_id):
        raise ValueError(f"Unsafe vault_id rejected: {vault_id!r}")
    if not _B64_RE.fullmatch(path_hmac_b64):
        raise ValueError(f"Unsafe path_hmac rejected: {path_hmac_b64!r}")

    sql = (
        "SELECT j.state, j.errors::text FROM oban_jobs j JOIN notes n "
        "ON j.args->>'note_id' = n.id::text "
        f"WHERE n.vault_id = '{vault_id}' "
        f"AND n.path_hmac = decode('{path_hmac_b64}', 'base64') "
        "AND j.worker = 'Engram.Workers.EmbedNote' "
        "ORDER BY j.id DESC LIMIT 1;"
    )
    result = subprocess.run(
        ["docker", "exec", "-i", CI_POSTGRES_CONTAINER,
         "psql", "-U", "engram", "-d", "engram", "-tA", "-F", "\t", "-c", sql],
        capture_output=True, text=True, timeout=10,
    )
    if result.returncode != 0:
        raise RuntimeError(f"_embed_job_state({vault_id}) failed: {result.stderr.strip()}")
    out = result.stdout.strip()
    if not out:
        return None, ""
    state, _, errors = out.partition("\t")
    return state, errors


def wait_for_qdrant_indexed(
    vault_id: str,
    path_hmac_b64: str,
    path: str | None = None,
    timeout: float = 30.0,
    hard_cap: float = 120.0  # < pytest-timeout 180s so this error fires first,
) -> None:
    """Wait for a Qdrant point whose `path_hmac` matches, following the EmbedNote job.

    #590: matches on the non-sensitive `path_hmac` (base64); get it from
    `latest_note_path_hmac/1` right after seeding. `path` is for messages only.

    `timeout` is "no progress for this long": while the embed job is alive
    (available/scheduled/executing/retryable) the wait continues up to
    `hard_cap`; a discarded/cancelled job raises RuntimeError at once with its
    errors; a completed or missing job with no point after `timeout` raises
    TimeoutError.
    """
    start = time.monotonic()
    idle_deadline = start + timeout
    state: str | None = None
    while True:
        if _qdrant_has_point(vault_id, path_hmac_b64):
            return
        state, errors = _embed_job_state(vault_id, path_hmac_b64)
        now = time.monotonic()
        if state in _DEAD_STATES:
            raise RuntimeError(
                f"EmbedNote job {state} for vault_id={vault_id} path={path!r} "
                f"(path_hmac={path_hmac_b64}): {errors}"
            )
        if state in _ALIVE_STATES:
            idle_deadline = now + timeout
            if now - start >= hard_cap:
                break
        elif now >= idle_deadline:
            break
        time.sleep(1)
    raise TimeoutError(
        f"Qdrant never indexed vault_id={vault_id} path={path!r} "
        f"(path_hmac={path_hmac_b64}); last embed job state={state!r} "
        f"after {time.monotonic() - start:.0f}s"
    )


def wait_for_chunks_committed(
    vault_id: str, path_hmac_b64: str, path: str | None = None, timeout: float = 30.0
) -> None:
    """Poll Postgres until the note matching `path_hmac_b64` has chunk rows.

    `wait_for_qdrant_indexed` is NOT enough before hitting `/api/search`:
    `Indexing.commit_index/1` upserts Qdrant first and inserts the `chunks`
    rows after, and the search read path rehydrates each hit from its chunk
    row (by qdrant_point_id). A hit with no row yet carries no source_path and
    is dropped by `collapse_to_notes`, so a search in that window misses the
    note. Raises TimeoutError on timeout. `path` is for the error message only.
    """
    if not _UUID_RE.match(vault_id):
        raise ValueError(f"Unsafe vault_id rejected: {vault_id!r}")
    if not re.fullmatch(r"[A-Za-z0-9+/=]+", path_hmac_b64):
        raise ValueError(f"Unsafe path_hmac rejected: {path_hmac_b64!r}")

    sql = (
        "SELECT count(*) FROM chunks c JOIN notes n ON n.id = c.note_id "
        f"WHERE n.vault_id = '{vault_id}' "
        f"AND n.path_hmac = decode('{path_hmac_b64}', 'base64');"
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = subprocess.run(
            ["docker", "exec", "-i", CI_POSTGRES_CONTAINER,
             "psql", "-U", "engram", "-d", "engram", "-tA", "-c", sql],
            capture_output=True, text=True, timeout=10,
        )
        if result.returncode != 0:
            raise RuntimeError(
                f"wait_for_chunks_committed({vault_id}) failed: {result.stderr.strip()}"
            )
        if int(result.stdout.strip() or 0) > 0:
            return
        time.sleep(1)
    raise TimeoutError(
        f"chunk rows never committed for vault_id={vault_id} path={path!r} "
        f"(path_hmac={path_hmac_b64}) within {timeout}s"
    )


def assert_attachment_ciphertext_at_rest(vault_id: str, path: str) -> None:
    """Phase B.4: stub. The plaintext-path lookup is gone. Test_19's
    assertion is currently skipped pending a release-rpc-based rebuild
    (translate path → path_hmac under user filter_key, then SELECT)."""
    raise NotImplementedError(
        "assert_attachment_ciphertext_at_rest needs rebuild post-B.3/B.4 — "
        "use release rpc to translate plaintext path → path_hmac before SELECT."
    )
