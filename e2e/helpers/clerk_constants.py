"""Canonical identification of e2e-created Clerk users.

Single source of truth shared by the in-run sweep (helpers/cleanup.py) and the
hourly reaper (scripts/cleanup_clerk_users.py). Historically each used its own
hard-coded list of email *prefixes*, and every new test suite added a prefix
(e2e-conn-, e2e-free-signup-, e2e-cancel-free-, …) that one or both lists
forgot — so those users leaked until the dev-tier 100-user cap was hit (#558).

Every e2e Clerk user is minted with an ``e2e-`` local part AND the
``+clerk_test`` plus-tag (the dev-instance "don't deliver email" convention,
see helpers/clerk.py + conftest.py). Matching on that signature is robust to
new suites and cannot match a real user.
"""

from __future__ import annotations


def is_e2e_clerk_email(email: str) -> bool:
    """True iff `email` belongs to an e2e-minted Clerk test user."""
    return email.startswith("e2e-") and "+clerk_test@" in email
