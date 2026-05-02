"""Cleanup helpers — removes test data from local CI postgres and local vaults."""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
from pathlib import Path

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

# CI compose project name — matches the directory name where docker-compose.ci.yml lives
CI_POSTGRES_CONTAINER = os.environ.get("CI_POSTGRES_CONTAINER", "engram-postgres-1")


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


_E2E_EMAIL_PREFIXES = ("e2e-sync-", "e2e-iso-", "e2e-vault-iso-", "e2e-oauth-", "e2e-clerk-")


def cleanup_all_e2e_clerk_users(clerk_client) -> int:
    """Find and delete ALL e2e-* users in the Clerk instance.

    This is the nuclear option — it doesn't rely on fixture-tracked IDs,
    so it catches orphans left by crashed fixtures or failed test runs.
    Returns the number of users deleted.
    """
    deleted = 0
    offset = 0
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
            if any(e.startswith(pfx) for e in emails for pfx in _E2E_EMAIL_PREFIXES):
                try:
                    clerk_client.delete_user(user["id"])
                    deleted += 1
                except Exception as exc:
                    logger.warning("Failed to delete Clerk user %s: %s", user["id"], exc)
        if len(batch) < 100:
            break
        offset += 100
    if deleted:
        logger.info("Cleaned up %d orphaned e2e Clerk users", deleted)
    return deleted


def cleanup_vaults() -> None:
    """Remove all E2E vault and config directories."""
    for path in VAULT_PATHS + CONFIG_PATHS:
        if path.exists():
            shutil.rmtree(path)
            logger.info("Removed %s", path)


def full_cleanup() -> None:
    """Run both DB and vault cleanup."""
    cleanup_test_data("e2e-%@example.com")
    cleanup_test_data("e2e-%@test.local")
    cleanup_vaults()


if __name__ == "__main__":
    """Allow running cleanup standalone: python -m e2e.helpers.cleanup"""
    logging.basicConfig(level=logging.INFO)
    full_cleanup()
    print("Cleanup complete.")
