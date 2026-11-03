#!/usr/bin/env python3
"""Bulk-delete stale E2E test users from a Clerk dev instance.

Usage:
    E2E_CLERK_SECRET_KEY=sk_test_... python e2e/scripts/cleanup_clerk_users.py [--dry-run]
    E2E_CLERK_SECRET_KEY=sk_test_... python e2e/scripts/cleanup_clerk_users.py --older-than 1h
    STAGING_CLERK_SECRET_KEY=sk_test_... python e2e/scripts/cleanup_clerk_users.py \
        --target staging --older-than 7d [--dry-run]

Fetches all Clerk users, filters to test-user email patterns, and deletes them.
``--target ci`` (default) owns e2e-* users on the CI instance. ``--target
staging`` owns ad-hoc ``+clerk_test@example.com`` accounts on the staging
instance (except load-sim-*), and only once BOTH creation and last activity
are older than ``--older-than``. Each target reads its own secret env var
(``SECRET_ENV``) so the CI and staging keys cannot be crossed.
The ``--older-than`` filter is the safety belt for the per-run reaper (verify.yml e2e-clerk) and the daily
``cron.yml`` backstop: without it, a reaper could
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

# Identify e2e users via the shared predicate (e2e- local part + +clerk_test
# tag) rather than a per-suite prefix list — the old hard-coded lists kept
# missing new suites (e2e-conn-, …), leaking users until the 100-user cap (#558).
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
from helpers.clerk_constants import (  # noqa: E402
    is_e2e_clerk_email,
    is_staging_test_clerk_email,
)

SECRET_ENV = {"ci": "E2E_CLERK_SECRET_KEY", "staging": "STAGING_CLERK_SECRET_KEY"}


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


def is_target_user(user: dict, target: str) -> bool:
    """Check if a Clerk user is a test user owned by this reaper target.

    staging requires EVERY email to match: one real address on the account
    means a human may own it, so it is kept.
    """
    emails = [ea.get("email_address", "") for ea in user.get("email_addresses", [])]
    if target == "staging":
        return bool(emails) and all(is_staging_test_clerk_email(e) for e in emails)
    return any(is_e2e_clerk_email(e) for e in emails)


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


def _age(raw, now: datetime) -> timedelta | None:
    """Age of a Clerk unix-millis timestamp (per Clerk Backend API docs). None if unknown."""
    if raw is None:
        return None
    try:
        return now - datetime.fromtimestamp(int(raw) / 1000, tz=timezone.utc)
    except (TypeError, ValueError):
        return None


def is_old_enough(user: dict, now: datetime, older_than: timedelta, target: str) -> bool:
    """Age gate. ci: created_at only. staging: created_at AND last activity
    (last_active_at, else last_sign_in_at, else never active) must be older.
    Unknown created_at is always kept."""
    created = _age(user.get("created_at"), now)
    if created is None or created < older_than:
        return False
    if target != "staging":
        return True
    activity = user.get("last_active_at") or user.get("last_sign_in_at")
    if activity is None:
        return True
    active = _age(activity, now)
    return active is not None and active >= older_than


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
    parser.add_argument(
        "--target",
        choices=sorted(SECRET_ENV),
        default="ci",
        help="ci: e2e-* users on the CI instance. staging: +clerk_test@example.com "
        "users on the staging instance (load-sim-* kept); requires --older-than.",
    )
    args = parser.parse_args()
    if args.target == "staging" and args.older_than is None:
        parser.error("--target staging requires --older-than")

    secret_env = SECRET_ENV[args.target]
    secret = os.environ.get(secret_env, "")
    if not secret:
        logger.error("%s not set", secret_env)
        sys.exit(1)

    session = requests.Session()
    session.headers["Authorization"] = f"Bearer {secret}"
    session.headers["Content-Type"] = "application/json"

    logger.info("Fetching all Clerk users...")
    all_users = get_all_users(session)
    logger.info("Total users in instance: %d", len(all_users))

    e2e_users = [u for u in all_users if is_target_user(u, args.target)]
    non_e2e = len(all_users) - len(e2e_users)
    logger.info(
        "[%s] Test users: %d | Other users: %d", args.target, len(e2e_users), non_e2e
    )

    if args.older_than is not None:
        now = datetime.now(timezone.utc)
        before = len(e2e_users)
        e2e_users = [
            u
            for u in e2e_users
            if is_old_enough(u, now, args.older_than, args.target)
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

    verb = "Would delete" if args.dry_run else "Deleted"
    logger.info("Done. %s %d %s test users.", verb, len(e2e_users), args.target)


if __name__ == "__main__":
    main()
