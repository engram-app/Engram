"""Database + Qdrant probes for at-rest encryption assertions.

Used by E2E tests that need to verify ciphertext is actually at rest
(not just that the API returns plaintext). Mirrors the docker-exec psql
pattern from cleanup.py.
"""

from __future__ import annotations

import json
import logging
import os
import re
import subprocess
import time

import requests

logger = logging.getLogger(__name__)

CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")
QDRANT_URL = os.environ.get("QDRANT_URL", "http://10.0.20.201:6333")
QDRANT_COLLECTION = os.environ.get("QDRANT_COLLECTION", "ci_test_notes")


def _psql(sql: str, *, fetch: bool = False) -> str:
    """Run SQL via docker exec psql. Returns stdout (or raises on error)."""
    args = ["-v", "ON_ERROR_STOP=1"]
    if fetch:
        args += ["-t", "-A", "-F", "|"]  # tuples-only, unaligned, pipe-separated
    cmd = ["docker", "exec", "-i", CI_POSTGRES_CONTAINER, "psql", "-U", "engram", "-d", "engram", *args]
    result = subprocess.run(cmd, input=sql, capture_output=True, text=True, timeout=15)
    if result.returncode != 0:
        raise RuntimeError(f"psql failed: {result.stderr.strip()}\nSQL: {sql!r}")
    return result.stdout.strip()


def _fetch_note_row(vault_id: int, path: str) -> dict:
    """SELECT the encryption columns for a note. Returns dict or raises AssertionError
    if the note doesn't exist."""
    sql = (
        f"\\set target_path '{path}'\n"
        f"SELECT (content IS NULL OR content = ''), (title IS NULL OR title = ''), "
        f"content_ciphertext IS NOT NULL, content_nonce IS NOT NULL, "
        f"title_ciphertext IS NOT NULL, title_nonce IS NOT NULL, tags_ciphertext IS NOT NULL "
        f"FROM notes WHERE vault_id = {int(vault_id)} AND path = :'target_path';"
    )
    out = _psql(sql, fetch=True)
    assert out, f"Note not found in DB: vault_id={vault_id} path={path!r}"
    line = out.splitlines()[0]
    c_cleared, t_cleared, c_ct, c_n, t_ct, t_n, tag_ct = line.split("|")
    return {
        "content_cleared": c_cleared == "t",
        "title_cleared": t_cleared == "t",
        "content_ciphertext_present": c_ct == "t",
        "content_nonce_present": c_n == "t",
        "title_ciphertext_present": t_ct == "t",
        "title_nonce_present": t_n == "t",
        "tags_ciphertext_present": tag_ct == "t",
    }


def assert_note_ciphertext_at_rest(vault_id: int, path: str) -> None:
    """Assert the note at (vault_id, path) is stored as ciphertext."""
    row = _fetch_note_row(vault_id, path)
    failures = []
    if not row["content_cleared"]:
        failures.append("content is not cleared (not NULL and not empty)")
    if not row["title_cleared"]:
        failures.append("title is not cleared (not NULL and not empty)")
    if not row["content_ciphertext_present"]:
        failures.append("content_ciphertext is NULL")
    if not row["content_nonce_present"]:
        failures.append("content_nonce is NULL")
    if not row["title_ciphertext_present"]:
        failures.append("title_ciphertext is NULL")
    if not row["title_nonce_present"]:
        failures.append("title_nonce is NULL")
    assert not failures, (
        f"Expected ciphertext at rest for vault_id={vault_id} path={path!r}; "
        f"failures: {failures}"
    )


def assert_note_plaintext_at_rest(vault_id: int, path: str) -> None:
    """Inverse. Content column populated, ciphertext columns NULL."""
    row = _fetch_note_row(vault_id, path)
    failures = []
    if row["content_cleared"]:
        failures.append("content is cleared (NULL or empty — expected plaintext)")
    if row["content_ciphertext_present"]:
        failures.append("content_ciphertext is set (expected NULL)")
    if row["content_nonce_present"]:
        failures.append("content_nonce is set (expected NULL)")
    if row["title_ciphertext_present"]:
        failures.append("title_ciphertext is set (expected NULL)")
    if row["title_nonce_present"]:
        failures.append("title_nonce is set (expected NULL)")
    assert not failures, (
        f"Expected plaintext at rest for vault_id={vault_id} path={path!r}; "
        f"failures: {failures}"
    )


def _qdrant_scroll(vault_id: int, limit: int = 100) -> list[dict]:
    """POST /collections/{coll}/points/scroll with a vault_id filter."""
    resp = requests.post(
        f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
        json={
            "filter": {"must": [{"key": "vault_id", "match": {"value": str(int(vault_id))}}]},
            "limit": limit,
            "with_payload": True,
            "with_vector": False,
        },
        timeout=10,
    )
    resp.raise_for_status()
    return resp.json()["result"]["points"]


def assert_qdrant_ciphertext(vault_id: int, min_chunks: int = 1) -> None:
    """Assert Qdrant payload for this vault contains ciphertext, not plaintext.
    Phase 4 spec: when a vault is encrypted, text/title/heading_path are
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


def assert_qdrant_plaintext(vault_id: int, min_chunks: int = 1) -> None:
    """Inverse — no *_nonce keys, plaintext text present."""
    points = _qdrant_scroll(vault_id)
    assert len(points) >= min_chunks, (
        f"Expected >= {min_chunks} Qdrant points for vault_id={vault_id}, got {len(points)}"
    )
    failures = []
    for i, p in enumerate(points[:min_chunks]):
        payload = p.get("payload", {})
        for nonce_key in ("text_nonce", "title_nonce", "heading_path_nonce"):
            if nonce_key in payload:
                failures.append(f"point[{i}] payload has {nonce_key!r} (expected plaintext)")
        if not payload.get("text"):
            failures.append(f"point[{i}] payload missing 'text'")
    assert not failures, (
        f"Expected Qdrant plaintext for vault_id={vault_id}; failures: {failures}"
    )


def _looks_base64(s: str) -> bool:
    """Base64 heuristic: only [A-Za-z0-9+/=], length multiple of 4, no spaces."""
    if " " in s or "\n" in s:
        return False
    if len(s) % 4 != 0:
        return False
    return bool(re.fullmatch(r"[A-Za-z0-9+/=]+", s))


def wait_for_encryption_status(
    api_client, vault_id: int, target: str, *, timeout: float = 60.0
) -> dict:
    """Poll GET /api/vaults/:id/encryption_progress every 1s until
    status == target. Returns last response body. Raises TimeoutError otherwise.

    `api_client` must be an authenticated ApiClient (api_sync or vault-scoped)."""
    api_url = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
    deadline = time.monotonic() + timeout
    last_body = None
    while time.monotonic() < deadline:
        resp = api_client.session.get(
            f"{api_url}/vaults/{vault_id}/encryption_progress",
            timeout=5,
        )
        if resp.ok:
            last_body = resp.json()
            if last_body.get("status") == target:
                return last_body
        time.sleep(1)
    raise TimeoutError(
        f"Vault {vault_id} never reached encryption_status={target!r} within {timeout}s; "
        f"last body: {last_body!r}"
    )


def backdate_last_toggle(vault_id: int, *, days: int) -> None:
    """Shift vaults.last_toggle_at into the past so cooldown check passes.
    Used between encrypt and decrypt steps in a single test run."""
    sql = (
        f"UPDATE vaults SET last_toggle_at = last_toggle_at - interval '{int(days)} days' "
        f"WHERE id = {int(vault_id)};"
    )
    _psql(sql)


def backdate_decrypt_requested(vault_id: int, *, hours: int) -> None:
    """Shift decrypt_requested_at AND the scheduled Oban DecryptVault job's
    scheduled_at into the past so the scheduler picks it up immediately."""
    sql = (
        f"UPDATE vaults SET decrypt_requested_at = decrypt_requested_at - interval '{int(hours)} hours' "
        f"WHERE id = {int(vault_id)}; "
        f"UPDATE oban_jobs SET scheduled_at = scheduled_at - interval '{int(hours)} hours' "
        f"WHERE worker = 'Engram.Workers.DecryptVault' "
        f"AND (args->>'vault_id')::int = {int(vault_id)} "
        f"AND state = 'scheduled';"
    )
    _psql(sql)


def wait_for_qdrant_indexed(vault_id: int, path: str, timeout: float = 30.0) -> None:
    """Poll Qdrant for a point whose source_path matches `path`. Raises TimeoutError
    on timeout. Needed before probing Qdrant ciphertext in tests because the embed
    worker is async."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            resp = requests.post(
                f"{QDRANT_URL}/collections/{QDRANT_COLLECTION}/points/scroll",
                json={
                    "filter": {
                        "must": [
                            {"key": "vault_id", "match": {"value": str(int(vault_id))}},
                            {"key": "source_path", "match": {"value": path}},
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
        f"Qdrant never indexed vault_id={vault_id} path={path!r} within {timeout}s"
    )


def set_user_cooldown_days(user_id: int, days: int | None) -> None:
    """Set users.encryption_toggle_cooldown_days for cooldown E2E tests.
    Pass `None` to clear the column (server treats NULL as "no cooldown")."""
    value = "NULL" if days is None else str(int(days))
    _psql(
        f"UPDATE users SET encryption_toggle_cooldown_days = {value} "
        f"WHERE id = {int(user_id)};"
    )


def get_user_id_for_vault(vault_id: int) -> int:
    """Look up the owning user_id for a vault. Used by tests that need to
    set per-user encryption settings without going through the API."""
    out = _psql(
        f"SELECT user_id FROM vaults WHERE id = {int(vault_id)};",
        fetch=True,
    )
    assert out, f"Vault not found in DB: vault_id={vault_id}"
    return int(out.splitlines()[0])
