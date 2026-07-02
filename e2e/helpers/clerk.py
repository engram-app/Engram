"""Clerk Backend API client for E2E test user management.

Used to clean up test users created during Playwright browser tests.
Requires CLERK_SECRET_KEY (sk_test_...) from environment.

Clerk Backend API docs: https://clerk.com/docs/reference/backend-api
"""

from __future__ import annotations

import logging
import random
import time

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

logger = logging.getLogger(__name__)

# Clerk's POST /sessions endpoint is eventually consistent vs POST /users:
# a user_id Clerk just returned can 404 from POST /sessions for a while.
# Observed window today (issue #193) is up to ~6s in degraded periods;
# in normal operation it's sub-second.
#
# Strategy (revised again for #869):
#   - create_user() blocks until POST /sessions stops 404'ing (readiness
#     probe). Concentrates the wait at one site instead of every caller
#     racing the propagation.
#   - _create_session_with_retry is the backstop — and it must be wall-clock
#     budgeted, not attempt-capped: propagation is NON-monotonic. One probe
#     success does not pin the user to every replica, so a later POST
#     /sessions can 404 again for seconds (#869 hit this 4x in one day with
#     the old ~3s / 5-attempt cap while the same commit passed on rerun).
_SESSION_READY_MAX_WAIT_SECONDS = 60.0
_SESSION_READY_INITIAL_BACKOFF = 0.5
_SESSION_READY_MAX_BACKOFF = 8.0

_SESSION_CREATE_MAX_WAIT_SECONDS = 30.0
_SESSION_CREATE_INITIAL_BACKOFF = 0.2
_SESSION_CREATE_MAX_BACKOFF = 4.0


class ClerkPropagationTimeout(RuntimeError):
    """Raised when Clerk's POST /sessions still 404s the user after the
    readiness probe's wall-clock budget."""


class ClerkClient:
    """Clerk Backend API client for E2E test user lifecycle.

    Supports creating users, obtaining session tokens, and cleanup —
    all via the Backend API, no browser needed.
    """

    def __init__(self, secret_key: str):
        self.session = requests.Session()
        self.session.headers["Authorization"] = f"Bearer {secret_key}"
        self.session.headers["Content-Type"] = "application/json"
        self.base_url = "https://api.clerk.dev/v1"
        # Every user this client creates, tracked so session teardown can delete
        # the exact set it made — even ones whose id never reached the caller's
        # try/finally (readiness-probe timeout) or whose test crashed before its
        # own cleanup. Scoped to THIS client's creations, so it never races a
        # sibling run's users. The hourly orphan reaper stays as the backstop
        # for hard crashes that skip teardown entirely.
        self.created_user_ids: set[str] = set()
        # Clerk rate-limits the Backend API (429). Without backoff, a burst of
        # e2e runs fails create/delete hard mid-suite — which then skips the
        # per-test cleanup and leaks users (compounding the quota problem).
        # Retry 429 + transient 5xx with exponential backoff, honoring the
        # Retry-After header. POST/DELETE are included: a 429'd request was
        # rejected (not processed), and create_user already handles the
        # idempotent "identifier taken" case, so retrying is safe.
        retry = Retry(
            total=5,
            backoff_factor=1.0,  # 1s, 2s, 4s, 8s, 16s
            status_forcelist=(429, 500, 502, 503, 504),
            allowed_methods=frozenset({"GET", "POST", "DELETE"}),
            respect_retry_after_header=True,
            raise_on_status=False,
        )
        adapter = HTTPAdapter(max_retries=retry)
        self.session.mount("https://", adapter)

    def find_user_by_email(self, email: str) -> str | None:
        """Find a Clerk user ID by email address. Returns user_id or None."""
        resp = self.session.get(
            f"{self.base_url}/users",
            params={"email_address": email},
            timeout=10,
        )
        resp.raise_for_status()
        users = resp.json()
        if not users:
            return None
        return users[0]["id"]

    def create_user(self, email: str, password: str) -> str:
        """Create a Clerk user via Backend API. Returns user_id.

        Idempotent: if Clerk reports the email as already taken (422
        form_identifier_exists), returns the existing user's ID rather
        than raising. Handles the common case where a prior fixture
        created the user but a downstream step (API key creation,
        network hiccup) failed mid-setup, causing pytest-rerunfailures
        to re-invoke provision_user with the same email.
        """
        # Strip the `+clerk_test` plus-tag (or any plus-tag) before deriving
        # the username — Clerk rejects `+` in usernames with 422
        # form_username_invalid, which would otherwise surface as a
        # confusing "create_user failed" error.
        username = email.split("@")[0].split("+")[0]
        resp = self.session.post(
            f"{self.base_url}/users",
            json={
                "email_address": [email],
                "username": username,
                "password": password,
                "skip_password_checks": True,
            },
            timeout=10,
        )
        if resp.status_code == 422 and self._is_identifier_taken(resp):
            existing_id = self.find_user_by_email(email)
            if existing_id:
                logger.warning(
                    "Clerk user %s already exists for %s — reusing", existing_id, email
                )
                self.created_user_ids.add(existing_id)
                return existing_id
            logger.error(
                "Clerk says %s is taken but lookup found nothing: %s",
                email, resp.text,
            )
        if not resp.ok:
            logger.error("Clerk create_user failed for %s: %s %s", email, resp.status_code, resp.text)
        resp.raise_for_status()
        user_id = resp.json()["id"]
        # Track BEFORE the readiness probe: if that raises, the id never reaches
        # the caller, but teardown must still be able to delete it.
        self.created_user_ids.add(user_id)
        logger.info("Created Clerk user %s (%s)", user_id, email)
        # Block until Clerk's session endpoint can see this user. Without
        # this, every downstream caller (create_session_token, JWT mint,
        # etc.) races Clerk's propagation lag — see #193.
        #
        # If readiness fails (timeout, rate-limit), the user already exists in
        # Clerk but the id never reaches the caller's try/finally — so it would
        # orphan and leak. Delete it best-effort before propagating the error.
        try:
            self._wait_until_session_ready(user_id)
        except Exception:
            logger.warning(
                "session-ready failed for %s (%s) — deleting to avoid orphan",
                user_id, email,
            )
            try:
                self.delete_user(user_id)
            except Exception as del_err:
                logger.error("orphan cleanup failed for %s: %s", user_id, del_err)
            raise
        return user_id

    def _wait_until_session_ready(self, user_id: str) -> None:
        """Block until Clerk's POST /sessions stops 404'ing the given user.

        Eventual consistency: a user just created via POST /users can be
        invisible to POST /sessions for seconds (up to ~6s observed; #193).
        This probe creates one Clerk session and discards it — once it
        succeeds, the user is queryable from the session endpoint and
        subsequent legitimate session creation will not race.

        Raises ClerkPropagationTimeout when Clerk doesn't propagate
        within _SESSION_READY_MAX_WAIT_SECONDS. Other errors (auth,
        rate-limit, etc.) raise immediately — we only loop on the
        specific 404 resource_not_found signal.
        """
        deadline = time.monotonic() + _SESSION_READY_MAX_WAIT_SECONDS
        backoff = _SESSION_READY_INITIAL_BACKOFF
        attempt = 0
        while True:
            attempt += 1
            resp = self.session.post(
                f"{self.base_url}/sessions",
                json={"user_id": user_id},
                timeout=10,
            )
            if resp.ok:
                session_id = resp.json()["id"]
                logger.info(
                    "Clerk session-ready probe succeeded for %s on attempt %d (session %s discarded)",
                    user_id, attempt, session_id,
                )
                return
            if not (resp.status_code == 404 and self._is_resource_not_found(resp)):
                logger.error(
                    "Clerk session-ready probe failed (non-404): %s %s",
                    resp.status_code, resp.text,
                )
                resp.raise_for_status()
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise ClerkPropagationTimeout(
                    f"Clerk POST /sessions still 404 for user {user_id} after "
                    f"{_SESSION_READY_MAX_WAIT_SECONDS}s ({attempt} attempts)"
                )
            # ±20% jitter avoids thundering-herd on Clerk when many tests
            # provision users in parallel during a degraded window.
            sleep_for = min(
                backoff + random.uniform(-0.2 * backoff, 0.2 * backoff),
                remaining,
            )
            logger.warning(
                "Clerk session-ready probe 404 for %s (attempt %d, sleeping %.2fs, %.1fs remaining)",
                user_id, attempt, sleep_for, remaining,
            )
            time.sleep(sleep_for)
            backoff = min(backoff * 2, _SESSION_READY_MAX_BACKOFF)

    @staticmethod
    def _is_identifier_taken(resp: requests.Response) -> bool:
        try:
            errors = resp.json().get("errors", [])
        except ValueError:
            return False
        return any(e.get("code") == "form_identifier_exists" for e in errors)

    def create_session_token(self, user_id: str) -> str:
        """Create a session for a user and return a short-lived JWT.

        Uses Clerk's Backend API to create a session, then mints a
        session token (valid ~60s). This JWT can be used as a Bearer
        token or injected as Clerk's __session cookie.

        Retries POST /sessions on transient 404 resource_not_found
        (Clerk eventual-consistency lag between user create/lookup and
        session endpoint visibility). See `_create_session_with_retry`.
        """
        session_id = self._create_session_with_retry(user_id)

        # Mint session token (no retry needed — session is fresh)
        resp = self.session.post(
            f"{self.base_url}/sessions/{session_id}/tokens",
            timeout=10,
        )
        if not resp.ok:
            logger.error("Clerk create_token failed: %s %s", resp.status_code, resp.text)
        resp.raise_for_status()
        token = resp.json()["jwt"]
        logger.info("Created session token for user %s (session %s)", user_id, session_id)
        return token

    def _create_session_with_retry(self, user_id: str) -> str:
        """POST /sessions with capped-backoff retry on 404 resource_not_found.

        Wall-clock budgeted (_SESSION_CREATE_MAX_WAIT_SECONDS): Clerk's
        propagation is non-monotonic, so the readiness probe in create_user
        does not guarantee this call's replica has the user yet (#869).
        Returns the session_id. Raises on non-404 errors immediately, or
        once the budget is exhausted on persistent 404.
        """
        deadline = time.monotonic() + _SESSION_CREATE_MAX_WAIT_SECONDS
        backoff = _SESSION_CREATE_INITIAL_BACKOFF
        attempt = 0
        while True:
            attempt += 1
            resp = self.session.post(
                f"{self.base_url}/sessions",
                json={"user_id": user_id},
                timeout=10,
            )
            if resp.ok:
                return resp.json()["id"]
            if resp.status_code == 404 and self._is_resource_not_found(resp):
                if time.monotonic() + backoff <= deadline:
                    logger.warning(
                        "Clerk create_session 404 for user %s (attempt %d, sleeping %.2fs, budget %.0fs)",
                        user_id, attempt, backoff, _SESSION_CREATE_MAX_WAIT_SECONDS,
                    )
                    time.sleep(backoff)
                    backoff = min(backoff * 2, _SESSION_CREATE_MAX_BACKOFF)
                    continue
                logger.error(
                    "Clerk create_session 404 for user %s exhausted %.0fs budget (%d attempts): %s",
                    user_id, _SESSION_CREATE_MAX_WAIT_SECONDS, attempt, resp.text,
                )
            else:
                logger.error("Clerk create_session failed: %s %s", resp.status_code, resp.text)
            resp.raise_for_status()
            raise RuntimeError("unreachable")  # pragma: no cover

    @staticmethod
    def _is_resource_not_found(resp: requests.Response) -> bool:
        try:
            errors = resp.json().get("errors", [])
        except ValueError:
            return False
        return any(e.get("code") == "resource_not_found" for e in errors)

    def get_testing_token(self) -> str:
        """Get a Testing Token to bypass bot detection in Clerk's Frontend API."""
        resp = self.session.post(
            f"{self.base_url}/testing_tokens",
            timeout=10,
        )
        resp.raise_for_status()
        return resp.json()["token"]

    def delete_user(self, user_id: str) -> None:
        """Delete a Clerk user by ID."""
        resp = self.session.delete(
            f"{self.base_url}/users/{user_id}",
            timeout=10,
        )
        if resp.status_code == 404:
            logger.warning("Clerk user %s already deleted", user_id)
            self.created_user_ids.discard(user_id)
            return
        resp.raise_for_status()
        self.created_user_ids.discard(user_id)
        logger.info("Deleted Clerk user %s", user_id)

    def cleanup_tracked(self) -> int:
        """Delete every user this client created that's still alive — the
        per-run safety net. Catches users a test crashed before cleaning, or
        whose id never reached the caller (readiness-probe timeout). Best-
        effort: a failed delete is logged, not raised, so teardown never
        crashes. Returns the count deleted."""
        deleted = 0
        for user_id in list(self.created_user_ids):
            try:
                self.delete_user(user_id)
                deleted += 1
            except Exception as e:
                logger.warning("Tracked-user cleanup failed for %s: %s", user_id, e)
        return deleted

    def list_users(self, limit: int = 100, offset: int = 0) -> list[dict]:
        """List Clerk users with pagination."""
        resp = self.session.get(
            f"{self.base_url}/users",
            params={"limit": limit, "offset": offset, "order_by": "created_at"},
            timeout=15,
        )
        resp.raise_for_status()
        return resp.json()

    def cleanup_user(self, email: str) -> None:
        """Find and delete a user by email. No-op if not found."""
        user_id = self.find_user_by_email(email)
        if user_id:
            self.delete_user(user_id)
        else:
            logger.info("No Clerk user found for %s — skipping cleanup", email)
