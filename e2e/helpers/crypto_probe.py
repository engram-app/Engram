"""Database + Qdrant probes for at-rest encryption assertions.

Used by E2E tests that need to verify ciphertext is actually at rest
(not just that the API returns plaintext). Mirrors the docker-exec psql
pattern from cleanup.py.

Phase B.4: toggle helpers (`wait_for_encryption_status`, `backdate_*`,
`set_user_cooldown_days`, `assert_note_plaintext_at_rest`) and the
plaintext-path probes (`_fetch_note_row`, `_fetch_attachment_row`,
`assert_note_ciphertext_at_rest`, `assert_attachment_ciphertext_at_rest`)
were retired with the encryption toggle. The Qdrant probes survive
unchanged. To restore plaintext-path → row probes, add a release rpc
that translates the path under the user's filter_key and fetches by
path_hmac.
"""

from __future__ import annotations

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


def _qdrant_scroll(vault_id: str, limit: int = 100) -> list[dict]:
    """POST /collections/{coll}/points/scroll with a vault_id filter."""
    resp = requests.post(
        f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
        json={
            "filter": {"must": [{"key": "vault_id", "match": {"value": str(vault_id)}}]},
            "limit": limit,
            "with_payload": True,
            "with_vector": False,
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["result"]["points"]


def assert_qdrant_ciphertext(vault_id: str, min_chunks: int = 1) -> None:
    """Assert Qdrant payload for this vault contains ciphertext, not plaintext.
    Phase 4 spec: every encrypted vault has its text/title/heading_path
    replaced with *_ciphertext + *_nonce. Plaintext keys are absent."""
    points = _qdrant_scroll(vault_id)
    assert len(points) >= min_chunks, (
        f"Expected >= {min_chunks} Qdrant points for vault_id={vault_id}, got {len(points)}"
    )
    failures = []
    for i, p in enumerate(points[:min_chunks]):
        payload = p.get("payload", {})
        if "text_nonce" not in payload:
            failures.append(f"point[{i}] payload missing 'text_nonce'; keys: {sorted(payload.keys())}")
        if "title_nonce" not in payload:
            failures.append(f"point[{i}] payload missing 'title_nonce'")
        if "heading_path_nonce" not in payload:
            failures.append(f"point[{i}] payload missing 'heading_path_nonce'")
        text_val = payload.get("text", "")
        if text_val and not _looks_base64(text_val):
            failures.append(f"point[{i}] 'text' looks like plaintext: {text_val[:80]!r}")
    assert not failures, (
        f"Expected Qdrant ciphertext for vault_id={vault_id}; failures: {failures}"
    )


def _looks_base64(s: str) -> bool:
    """Base64 heuristic: only [A-Za-z0-9+/=], length multiple of 4, no spaces."""
    if " " in s or "\n" in s:
        return False
    if len(s) % 4 != 0:
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9+/=]+", s))


def wait_for_qdrant_indexed(
    vault_id: str, path_hmac_b64: str, path: str | None = None, timeout: float = 30.0
) -> None:
    """Poll Qdrant for a point whose `path_hmac` matches. Raises TimeoutError on
    timeout. Needed before probing Qdrant in tests because the embed worker is
    async.

    #590: matches on the non-sensitive `path_hmac` (base64) rather than the
    removed plaintext `source_path`. Get `path_hmac_b64` from
    `latest_note_path_hmac/1` right after seeding. `path` is plaintext for the
    error message only.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = requests.post(
                f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
                json={
                    "filter": {
                        "must": [
                            {"key": "vault_id", "match": {"value": str(vault_id)}},
                            {"key": "path_hmac", "match": {"value": path_hmac_b64}},
                        ]
                    },
                    "limit": 1,
                    "with_payload": False,
                    "with_vector": False,
                },
                timeout=5,
            )
            if resp.ok and resp.json()["result"]["points"]:
                return
        except (requests.ConnectionError, requests.Timeout, KeyError):
            pass
        time.sleep(1)
    raise TimeoutError(
        f"Qdrant never indexed vault_id={vault_id} path={path!r} "
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
