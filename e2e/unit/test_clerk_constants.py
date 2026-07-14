"""is_e2e_clerk_email must own EVERY e2e-minted user shape.

Regression guard for the #558 class recurring through the Playwright suite
(2026-07-14): frontend/e2e mints `e2e-*@test.com` users WITHOUT the
`+clerk_test` tag, so the reaper never deleted them — they accumulated to
the Clerk dev-tier 100-user cap and user creation started failing
("No user found with email" in every [clerk] browser test).
"""

import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from helpers.clerk_constants import is_e2e_clerk_email  # noqa: E402


def test_pytest_harness_shape_matches():
    assert is_e2e_clerk_email("e2e-sync-123r777je2e-clerkw0+clerk_test@example.com")


def test_playwright_untagged_shape_matches():
    # frontend/e2e/global-setup.ts + spec files: e2e-<suite>-<ts>@test.com
    assert is_e2e_clerk_email("e2e-browser-1784019046203@test.com")
    assert is_e2e_clerk_email("e2e-props-crdt-1784019046203@test.com")
    assert is_e2e_clerk_email("e2e-tree-delopen-1784019046203@test.com")


def test_real_users_never_match():
    assert not is_e2e_clerk_email("todd@example.com")
    assert not is_e2e_clerk_email("e2e-fan@gmail.com")          # e2e- prefix alone is NOT enough
    assert not is_e2e_clerk_email("someone+clerk_test@example.com")  # tag alone is NOT enough
    assert not is_e2e_clerk_email("")
