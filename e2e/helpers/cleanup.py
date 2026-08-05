"""Cleanup helpers — removes test data from local CI postgres and local vaults."""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
from datetime import datetime
from pathlib import Path

from helpers.clerk_constants import is_e2e_clerk_email

logger = logging.getLogger(__name__)

# The per-run timestamp embedded at the front of every e2e email's ts segment
# (conftest `ts` fixture: datetime.now().strftime("%Y%m%d%H%M%S%f") → 20 digits,
# immediately followed by "r{run_id}"). Used to age-gate the in-suite sweep.
_EMAIL_TS_RE = re.compile(r"(\d{20})r")


def _email_age_seconds(email: str) -> float | None:
    """Seconds since the e2e email's embedded timestamp, or None if absent/unparseable.

    Load-bearing assumption: the ts is minted (conftest `ts` fixture) and this
    sweep runs on the SAME host clock — naive-local `datetime.now()` on both
    sides. That holds because xdist workers are subprocesses of one CI runner.
    If the sweep ever moves to a different container/host than the minting
    worker, ages break silently (and the fail-safe would mask it as "keep all").
    """
    m = _EMAIL_TS_RE.search(email)
    if not m:
        return None
    try:
        created = datetime.strptime(m.group(1), "%Y%m%d%H%M%S%f")
    except ValueError:
        return None
    return (datetime.now() - created).total_seconds()

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
CI_MINIO_BUCKET = os.environ.get("CI_MINIO_BUCKET", "ci-local")
CI_MINIO_HOST = os.environ.get("CI_MINIO_HOST", "10.0.20.214")
CI_MINIO_PORT = os.environ.get("CI_MINIO_PORT", "9101")

# Buckets this module is allowed to purge. NOT stylistic.
#
# Attachments moved off a per-stack MinIO sidecar onto the central FastRaid
# MinIO (see ci/compose.yml). That host also holds staging's live
# `engram-saas-attachments` and selfhost's `engram-selfhost-attachments`, and
# the purge below is a recursive force-delete. Previously the blast radius was
# a throwaway container; now a wrong CI_MINIO_BUCKET would take staging's
# attachments with it.
#
# So the bucket name is validated here rather than trusted from the
# environment: config can be wrong, a guard on the shared teardown path
# cannot be bypassed by any caller.
_CI_BUCKET_PATTERN = re.compile(r"^ci-[a-z0-9][a-z0-9-]*$")


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


def cleanup_all_e2e_clerk_users(
    clerk_client,
    run_id: str | None = None,
    job_id: str | None = None,
    min_age_seconds: float = 0,
) -> int:
    """Find and delete e2e-* users in the Clerk instance.

    By default scopes the sweep to ``run_id`` + ``job_id`` — only emails
    containing ``r{run_id}j{job_id}w`` are deleted. Weaker scoping caused
    three cascades:

    - issue #160: no scoping — a run's worker-0 fixture nuked every e2e-*
      user, including sibling RUNS' active users (401 storms).
    - issue #869 (2026-07-02): run-only scoping — GITHUB_RUN_ID is shared
      by all parallel JOBS of one workflow run, so the e2e-api job's setup
      sweep deleted the e2e-clerk job's live users mid-suite (POST
      /sessions 404 in test_49; every e2e-clerk teardown delete already 404).
    - run 29670308705 (2026-07-19): run+job scoping is still WORKER-blind.
      The marker anchors on the trailing ``w``, so ``r{run}j{job}w`` matches
      every worker (``w0``, ``w1``). Under ``-n 2 --dist=loadfile`` only
      worker 0 runs this sweep, but at session start it raced worker 1's
      provisioning and deleted worker 1's freshly created live user →
      worker 1's ``create_session`` 404'd until the retry budget exhausted.

    ``job_id`` distinguishes sibling jobs. ``min_age_seconds`` distinguishes
    a prior *attempt*'s leftovers (minutes old on a re-run — safe to reap)
    from the *current* attempt's concurrently-provisioned users (age ~0s —
    a live sibling worker; must survive). Users younger than the floor, or
    whose embedded timestamp can't be parsed, are skipped (fail-safe: never
    risk a live user; the hourly clerk-orphans reaper catches true stragglers).
    Same ``--older-than`` discipline the standalone reaper already applies.

    Passing ``run_id=None`` restores the legacy nuclear behavior — useful
    only from the standalone reaper script (``scripts/cleanup_clerk_users.py``)
    which adds its own ``--older-than`` time-based safety filter.

    Returns the number of users deleted.
    """
    deleted = 0
    skipped_recent = 0
    offset = 0
    # Anchor on the trailing ``w`` so that run id "123" never substring-matches
    # into another run's "r12345w0" segment. Worker suffix is always present.
    if run_id and job_id:
        run_marker = f"r{run_id}j{job_id}w"
    elif run_id:
        run_marker = f"r{run_id}w"
    else:
        run_marker = None
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
            if min_age_seconds > 0:
                # Age-gate on the youngest e2e email: a concurrently-starting
                # sibling worker's just-provisioned user must not be reaped.
                ages = [_email_age_seconds(e) for e in emails if is_e2e_clerk_email(e)]
                parseable = [a for a in ages if a is not None]
                if not parseable or min(parseable) < min_age_seconds:
                    skipped_recent += 1
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
        if run_id and job_id:
            scope = f"run {run_id} job {job_id}"
        elif run_id:
            scope = f"run {run_id}"
        else:
            scope = "ALL runs"
        logger.info("Cleaned up %d orphaned e2e Clerk users (%s)", deleted, scope)
    if skipped_recent:
        logger.info(
            "Sweep kept %d recent/unverifiable e2e user(s) younger than %.0fs "
            "(live sibling-worker protection)",
            skipped_recent, min_age_seconds,
        )
    return deleted


def cleanup_vaults() -> None:
    """Remove all E2E vault and config directories."""
    for path in VAULT_PATHS + CONFIG_PATHS:
        if path.exists():
            shutil.rmtree(path)
            logger.info("Removed %s", path)


def cleanup_minio_bucket() -> None:
    """Best-effort removal of this run's bucket on the central MinIO.

    Attachments land in MinIO, so without this every run leaks its blobs —
    and since the move off the per-stack sidecar, leaks now accumulate on a
    shared host rather than dying with the container.

    Refuses any bucket outside the `ci-` namespace: the same host holds
    staging and selfhost attachments, and this is a recursive force-delete.
    """
    if not _CI_BUCKET_PATTERN.match(CI_MINIO_BUCKET):
        # Loud, and NOT best-effort. Reaching here means the environment
        # pointed teardown at something it must never touch; skipping the
        # purge silently would leave that misconfiguration live for the next
        # caller, which might not have a guard.
        raise ValueError(
            f"refusing to purge MinIO bucket {CI_MINIO_BUCKET!r}: "
            "e2e teardown may only delete buckets matching ^ci-. The central "
            "MinIO also holds staging (engram-saas-attachments) and selfhost "
            "(engram-selfhost-attachments) data."
        )

    access_key = os.environ.get("CI_MINIO_ACCESS_KEY", "")
    secret_key = os.environ.get("CI_MINIO_SECRET_KEY", "")
    if not access_key or not secret_key:
        logger.debug("MinIO purge skipped — no central MinIO credentials in env")
        return

    # `mc rb --force` removes contents AND the bucket: the bucket is per-run,
    # so leaving an empty one behind just accumulates a different kind of
    # litter on the shared host.
    inline = (
        f"mc alias set central http://{CI_MINIO_HOST}:{CI_MINIO_PORT} "
        f'"$CI_MINIO_ACCESS_KEY" "$CI_MINIO_SECRET_KEY" >/dev/null && '
        f"mc rb --force central/{CI_MINIO_BUCKET}"
    )
    cmd = [
        "docker", "run", "--rm",
        "-e", "CI_MINIO_ACCESS_KEY",
        "-e", "CI_MINIO_SECRET_KEY",
        "--entrypoint", "sh",
        "minio/mc:latest", "-c", inline,
    ]
    result = subprocess.run(
        cmd,
        capture_output=True,
        text=True,
        timeout=60,
        env={**os.environ, "CI_MINIO_ACCESS_KEY": access_key, "CI_MINIO_SECRET_KEY": secret_key},
    )

    if result.returncode != 0:
        stderr = result.stderr.strip()
        # A run that uploaded nothing never had the bucket created, and a
        # re-run of teardown finds it already gone — both are success.
        if "does not exist" in stderr.lower():
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
