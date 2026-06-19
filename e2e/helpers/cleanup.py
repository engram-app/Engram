"""Cleanup helpers — removes test data from local CI postgres and local vaults."""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
from pathlib import Path

from helpers.clerk_constants import is_e2e_clerk_email

logger = logging.getLogger(__name__)

VAULT_PATHS = [
    Path("/tmp/e2e-vault-a"),
    Path("/tmp/e2e-vault-b"),
    Path("/tmp/e2e-vault-c"),
]

# Obsidian config dirs — created by ObsidianInstance._prepare_config,
# normally cleaned up in stop(), but left behind on crashes.
CONFIG_PATHS = [
    Path("/tmp/e2e-obsidian-config-a"),
    Path("/tmp/e2e-obsidian-config-b"),
    Path("/tmp/e2e-obsidian-config-c"),
]

# CI compose project name — matches the directory name where ci/compose.yml lives
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")
CI_MINIO_CONTAINER = os.environ.get("CI_MINIO_CONTAINER", "engram-ci-minio-1")
CI_MINIO_BUCKET = os.environ.get("CI_MINIO_BUCKET", "engram-attachments")


_SAFE_EMAIL_PATTERN = re.compile(r"^[a-zA-Z0-9._@%+-]+$")


def cleanup_test_data(email_pattern: str = "e2e-%@example.com") -> None:
    """Run cleanup SQL via docker exec against the local CI postgres container.

    Deletes all users/notes/attachments/api_keys matching the email pattern.
    FK-safe deletion order. Uses psql variable binding to avoid SQL injection.
    """
    if not _SAFE_EMAIL_PATTERN.match(email_pattern):
        raise ValueError(f"Unsafe email pattern rejected: {email_pattern!r}")

    # Pattern is validated by _SAFE_EMAIL_PATTERN above, safe to interpolate.
    # psql -c does not expand :variable substitution, so we use a parameterized
    # query via psql's stdin with \set + :'var' quoting.
    # Elixir schema: notes.user_id and chunks.user_id have on_delete: :nothing,
    # so we must delete in FK-safe order (children before parents).
    sql_script = (
        f"\\set pat '{email_pattern}'\n"
        "DELETE FROM api_key_vaults WHERE api_key_id IN (SELECT id FROM api_keys WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat'));\n"
        "DELETE FROM api_keys WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM client_logs WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM chunks WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM notes WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM attachments WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM subscriptions WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM user_overrides WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM device_refresh_tokens WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM device_authorizations WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM vaults WHERE user_id IN (SELECT id FROM users WHERE email LIKE :'pat');\n"
        "DELETE FROM users WHERE email LIKE :'pat';\n"
    )

    cmd = [
        "docker", "exec", "-i", CI_POSTGRES_CONTAINER,
        "psql", "-U", "engram", "-d", "engram",
    ]

    logger.info("Running cleanup SQL on %s (pattern: %s)", CI_POSTGRES_CONTAINER, email_pattern)
    result = subprocess.run(cmd, input=sql_script, capture_output=True, text=True, timeout=30)

    if result.returncode != 0:
        stderr = result.stderr.strip()
        if "No such container" in stderr:
            logger.warning("Cleanup skipped — container %s not found", CI_POSTGRES_CONTAINER)
            return
        logger.error("Cleanup SQL failed: %s", stderr)
        raise RuntimeError(f"Cleanup failed: {stderr}")

    logger.info("Cleanup SQL output: %s", result.stdout.strip())


def cleanup_clerk_users(clerk_client, clerk_user_ids: list[str]) -> None:
    """Delete Clerk users by ID. Best-effort — logs errors but doesn't raise."""
    for user_id in clerk_user_ids:
        try:
            clerk_client.delete_user(user_id)
        except Exception as e:
            logger.warning("Failed to delete Clerk user %s: %s", user_id, e)


def cleanup_all_e2e_clerk_users(clerk_client, run_id: str | None = None) -> int:
    """Find and delete e2e-* users in the Clerk instance.

    By default scopes the sweep to ``run_id`` — only emails containing
    ``r{run_id}`` are deleted. This prevents the cross-run cascade
    documented in issue #160: a CI run's worker-0 fixture used to nuke
    every e2e-* user, including ones being actively used by sibling CI
    runs, causing HTTP 401 storms in those runs.

    Passing ``run_id=None`` restores the legacy nuclear behavior — useful
    only from the standalone reaper script (``scripts/cleanup_clerk_users.py``)
    which adds its own ``--older-than`` time-based safety filter.

    Returns the number of users deleted.
    """
    deleted = 0
    offset = 0
    # Anchor on the trailing ``w`` so that run id "123" never substring-matches
    # into another run's "r12345w0" segment. Worker suffix is always present.
    run_marker = f"r{run_id}w" if run_id else None
    while True:
        try:
            batch = clerk_client.list_users(limit=100, offset=offset)
        except Exception as e:
            logger.warning("Failed to list Clerk users at offset %d: %s", offset, e)
            break
        if not batch:
            break
        for user in batch:
            emails = [ea["email_address"] for ea in user.get("email_addresses", [])]
            if not any(is_e2e_clerk_email(e) for e in emails):
                continue
            if run_marker is not None and not any(run_marker in e for e in emails):
                continue
            try:
                clerk_client.delete_user(user["id"])
                deleted += 1
            except Exception as exc:
                logger.warning("Failed to delete Clerk user %s: %s", user["id"], exc)
        if len(batch) < 100:
            break
        offset += 100
    if deleted:
        scope = f"run {run_id}" if run_id else "ALL runs"
        logger.info("Cleaned up %d orphaned e2e Clerk users (%s)", deleted, scope)
    return deleted


def cleanup_vaults() -> None:
    """Remove all E2E vault and config directories."""
    for path in VAULT_PATHS + CONFIG_PATHS:
        if path.exists():
            shutil.rmtree(path)
            logger.info("Removed %s", path)


def cleanup_minio_bucket() -> None:
    """Best-effort purge of every object under the test bucket via `mc rm`.

    Required since attachments now land in MinIO; without this, repeated
    test runs accumulate orphan blobs across the bucket. No-op when the
    MinIO container is absent (e.g., a stack run with storage disabled).
    """
    # mc inside the minio container has no persistent alias config (the
    # minio-init sidecar that set the alias has exited), so configure
    # inline. `mc alias set` is idempotent.
    inline = (
        "mc alias set local http://localhost:9000 minioadmin minioadmin >/dev/null && "
        f"mc rm --recursive --force local/{CI_MINIO_BUCKET}/"
    )
    cmd = ["docker", "exec", CI_MINIO_CONTAINER, "sh", "-c", inline]
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=30)

    if result.returncode != 0:
        stderr = result.stderr.strip()
        if "No such container" in stderr or "not running" in stderr:
            logger.debug("MinIO purge skipped — container %s not present", CI_MINIO_CONTAINER)
            return
        # `mc rm` on an empty prefix prints "Failed to remove ...: Object does not exist"
        # but exits non-zero — treat as success.
        if "Object does not exist" in stderr or not stderr:
            return
        logger.warning("MinIO purge non-fatal error: %s", stderr)


def full_cleanup() -> None:
    """Run DB, blob, and vault cleanup."""
    cleanup_test_data("e2e-%@example.com")
    cleanup_test_data("e2e-%@test.local")
    cleanup_minio_bucket()
    cleanup_vaults()


if __name__ == "__main__":
    """Allow running cleanup standalone: python -m e2e.helpers.cleanup"""
    logging.basicConfig(level=logging.INFO)
    full_cleanup()
    print("Cleanup complete.")
