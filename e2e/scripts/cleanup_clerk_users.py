#!/usr/bin/env python3
"""Bulk-delete stale E2E test users from a Clerk dev instance.

Usage:
    E2E_CLERK_SECRET_KEY=sk_test_... python e2e/scripts/cleanup_clerk_users.py [--dry-run]
    E2E_CLERK_SECRET_KEY=sk_test_... python e2e/scripts/cleanup_clerk_users.py --older-than 1h

Fetches all Clerk users, filters to e2e-* email patterns, and deletes them.
The ``--older-than`` filter is the safety belt for the hourly cron reaper
(``.github/workflows/clerk-orphans.yml``): without it, the reaper could
race against an in-flight CI run whose users are still active. See issue #160.
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys
import time
from datetime import datetime, timedelta, timezone

import requests

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

CLERK_API = "https://api.clerk.dev/v1"
E2E_EMAIL_PREFIXES = (
    "e2e-sync-",
    "e2e-iso-",
    "e2e-vault-iso-",
    "e2e-oauth-",
    "e2e-clerk-",
    # Playwright frontend e2e (frontend/e2e/global-setup.ts) self-cleans
    # its own prefix at setup, but only when the job runs successfully.
    # When e2e-browser fails (Clerk quota, runner OOM, etc.) those users
    # leak; this reaper is the safety net. The 1h --older-than filter
    # protects in-flight Playwright runs from being culled.
    "e2e-browser-",
    # Onboarding wizard tests from the signup wizard work (PR #142 era).
    # The test code is gone but Clerk users persist; 70+ accumulated
    # since 2026-05-15 and ate most of the dev-tier 100-user cap.
    "e2e-onboard-",
    # Free-tier launch suite (PR #502): attachment quota, signup-on-free,
    # cancel-into-free. Each test fixture creates its own Clerk user that
    # leaks when the job fails post-create; ~100 accumulated by 2026-06-09
    # and re-hit the dev-tier 100-user cap.
    "e2e-free-att-",
    "e2e-free-signup-",
    "e2e-cancel-free-",
)


def get_all_users(session: requests.Session) -> list[dict]:
    """Paginate through all Clerk users."""
    users = []
    offset = 0
    limit = 100
    while True:
        resp = session.get(
            f"{CLERK_API}/users",
            params={"limit": limit, "offset": offset, "order_by": "created_at"},
            timeout=15,
        )
        resp.raise_for_status()
        batch = resp.json()
        if not batch:
            break
        users.extend(batch)
        if len(batch) < limit:
            break
        offset += limit
    return users


def is_e2e_user(user: dict) -> bool:
    """Check if a Clerk user was created by E2E tests."""
    for ea in user.get("email_addresses", []):
        email = ea.get("email_address", "")
        if any(email.startswith(prefix) for prefix in E2E_EMAIL_PREFIXES):
            return True
    return False


_DURATION_RE = re.compile(r"^(\d+)([smhd])$")


def parse_duration(s: str) -> timedelta:
    """Parse '30s', '15m', '1h', '2d' into a timedelta. Raises on bad input."""
    m = _DURATION_RE.match(s.strip().lower())
    if not m:
        raise argparse.ArgumentTypeError(
            f"Invalid duration {s!r}; expected forms like '30s', '15m', '1h', '2d'"
        )
    n, unit = int(m.group(1)), m.group(2)
    return {
        "s": timedelta(seconds=n),
        "m": timedelta(minutes=n),
        "h": timedelta(hours=n),
        "d": timedelta(days=n),
    }[unit]


def user_age(user: dict, now: datetime) -> timedelta | None:
    """Return how long ago this Clerk user was created. None if unknown.

    Clerk's ``created_at`` is unix-millis (per Clerk Backend API docs).
    """
    raw = user.get("created_at")
    if raw is None:
        return None
    try:
        created = datetime.fromtimestamp(int(raw) / 1000, tz=timezone.utc)
    except (TypeError, ValueError):
        return None
    return now - created


def main():
    parser = argparse.ArgumentParser(description="Delete stale E2E Clerk users")
    parser.add_argument("--dry-run", action="store_true", help="List users without deleting")
    parser.add_argument(
        "--older-than",
        type=parse_duration,
        default=None,
        help="Only delete users older than this (e.g. '1h', '30m', '2d'). "
        "Required by the cron reaper to avoid racing in-flight CI runs.",
    )
    args = parser.parse_args()

    secret = os.environ.get("E2E_CLERK_SECRET_KEY", "")
    if not secret:
        logger.error("E2E_CLERK_SECRET_KEY not set")
        sys.exit(1)

    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {secret}"
    session.headers["Content-Type"] = "application/json"

    logger.info("Fetching all Clerk users...")
    all_users = get_all_users(session)
    logger.info("Total users in instance: %d", len(all_users))

    e2e_users = [u for u in all_users if is_e2e_user(u)]
    non_e2e = len(all_users) - len(e2e_users)
    logger.info("E2E test users: %d | Real users: %d", len(e2e_users), non_e2e)

    if args.older_than is not None:
        now = datetime.now(timezone.utc)
        before = len(e2e_users)
        e2e_users = [
            u
            for u in e2e_users
            if (age := user_age(u, now)) is not None and age >= args.older_than
        ]
        logger.info(
            "Age filter --older-than %s: kept %d / %d e2e users",
            args.older_than,
            len(e2e_users),
            before,
        )

    if not e2e_users:
        logger.info("Nothing to clean up.")
        return

    for user in e2e_users:
        emails = [ea["email_address"] for ea in user.get("email_addresses", [])]
        email_str = ", ".join(emails)
        if args.dry_run:
            logger.info("[DRY RUN] Would delete: %s (%s)", user["id"], email_str)
        else:
            resp = session.delete(f"{CLERK_API}/users/{user['id']}", timeout=10)
            if resp.status_code == 404:
                logger.warning("Already deleted: %s (%s)", user["id"], email_str)
            elif resp.ok:
                logger.info("Deleted: %s (%s)", user["id"], email_str)
            else:
                logger.error("Failed to delete %s: %s %s", user["id"], resp.status_code, resp.text)
            # Respect rate limits
            time.sleep(0.1)

    logger.info("Done. Deleted %d e2e users.", len(e2e_users))


if __name__ == "__main__":
    main()
