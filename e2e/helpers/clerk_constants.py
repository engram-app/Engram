"""Canonical identification of e2e-created Clerk users.

Single source of truth shared by the in-run sweep (helpers/cleanup.py) and the
hourly reaper (scripts/cleanup_clerk_users.py). Historically each used its own
hard-coded list of email *prefixes*, and every new test suite added a prefix
(e2e-conn-, e2e-free-signup-, e2e-cancel-free-, …) that one or both lists
forgot — so those users leaked until the dev-tier 100-user cap was hit (#558).

The pytest harness mints users with an ``e2e-`` local part AND the
``+clerk_test`` plus-tag (the dev-instance "don't deliver email" convention,
see helpers/clerk.py + conftest.py). The Playwright browser suite
(frontend/e2e/global-setup.ts + spec files) mints ``e2e-<suite>-<ts>@test.com``
WITHOUT the tag — matching only the tag let those users leak past the reaper
until the dev-tier 100-user cap was hit AGAIN on 2026-07-14 (same class as
#558: every [clerk] browser test failed "No user found with email" because
user creation was rejected at the cap). So: own the tag signature OR any
``e2e-*@test.com`` address — ``@test.com`` is a test-only domain, no real
user has it, and both arms still require the ``e2e-`` prefix.
"""

from __future__ import annotations


def is_e2e_clerk_email(email: str) -> bool:
    """True iff `email` belongs to an e2e-minted Clerk test user."""
    return email.startswith("e2e-") and (
        "+clerk_test@" in email or email.endswith("@test.com")
    )
