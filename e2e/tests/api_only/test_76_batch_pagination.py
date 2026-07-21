"""Test 76: paginated /notes/changes (keyset pagination).

POST /notes/batch was removed with the CRDT single-push-path migration
(writes now ride the WS crdt_create_batch op, not a bulk REST endpoint), so
this suite seeds its fixture data via single-note POST /notes instead. The
pagination contract under test is unchanged:

  * GET /notes/changes caps every response at 500 rows and exposes
    has_more/next_cursor; a cursor loop covers the full delta with no
    loss and no duplicates.
  * Legacy convergence: a pre-pagination client that only advances
    ``since = server_time`` (no cursor) still collects EVERY change —
    server_time is anchored at the truncation point when has_more.
  * fields=meta swaps content for content_hash.

Seeds 1100 notes (3 pages) into the shared vault and batch-deletes them
afterwards so later suites see a clean slate.
"""

import os
import time
import uuid

import pytest

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"

SEED_COUNT = 1100  # > 2 full pages of 500
EPOCH = "2020-01-01T00:00:00Z"
PREFIX = "BatchPage"


def _get_changes(api, since: str, **params) -> dict:
    resp = api.session.get(
        f"{API_URL}/notes/changes",
        params={"since": since, **params},
        timeout=30,
    )
    assert resp.status_code == 200, f"changes failed: {resp.status_code} {resp.text}"
    return resp.json()


@pytest.fixture(scope="module")
def seeded(api_sync):
    """Seed SEED_COUNT notes via single-note POST /notes; batch-delete on teardown."""
    ids: list[str] = [
        api_sync.create_note(
            f"{PREFIX}/n{i:04d}.md", f"# Note {i}\n\nbatch-seeded", time.time()
        )["note"]["id"]
        for i in range(SEED_COUNT)
    ]

    yield ids

    # Cleanup — one atomic batch delete (no documented cap on ids).
    resp = api_sync.session.post(
        f"{API_URL}/notes/batch-delete",
        json={"ids": ids},
        headers={"X-Idempotency-Key": str(uuid.uuid4())},
        timeout=60,
    )
    assert resp.status_code == 200, f"cleanup failed: {resp.status_code} {resp.text}"


class TestPaginationConvergence:
    def test_cursor_loop_covers_full_delta(self, api_sync, seeded):
        """New-plugin shape: limit+cursor loop — complete, no duplicates."""
        seen: set[str] = set()
        cursor = None
        pages = 0
        while True:
            params = {"limit": 500, "fields": "meta"}
            if cursor:
                params["cursor"] = cursor
            page = _get_changes(api_sync, EPOCH, **params)
            pages += 1
            assert len(page["changes"]) <= 500
            for c in page["changes"]:
                if c["path"].startswith(f"{PREFIX}/n"):
                    assert c["path"] not in seen, f"duplicate across pages: {c['path']}"
                    seen.add(c["path"])
                # fields=meta: hash present, content absent
                assert "content" not in c
                assert c["content_hash"]
            if not page["has_more"]:
                assert page["next_cursor"] is None
                break
            cursor = page["next_cursor"]
            assert cursor, "has_more without next_cursor"
            assert pages < 50, "cursor loop did not converge"

        assert len(seen) == SEED_COUNT

    def test_legacy_since_polling_converges_without_loss(self, api_sync, seeded):
        """OLD-plugin shape: no limit/cursor, since = server_time each poll.

        The capped response anchors server_time at the truncation point, so
        successive polls walk the full delta instead of skipping the tail.
        This is the back-compat check the spec calls out — if it fails, the
        cap must be gated on a plugin-version header instead.
        """
        seen: set[str] = set()
        since = EPOCH
        polls = 0
        while polls < 50:
            page = _get_changes(api_sync, since)
            polls += 1
            for c in page["changes"]:
                if c["path"].startswith(f"{PREFIX}/n"):
                    seen.add(c["path"])
                    # Legacy (no fields param) pages still carry content.
                    assert "content" in c
            if len(seen) >= SEED_COUNT:
                break
            assert page["server_time"] > since or page["changes"], (
                "legacy poll made no progress — livelock"
            )
            since = page["server_time"]

        assert len(seen) == SEED_COUNT, (
            f"legacy polling lost changes: {len(seen)}/{SEED_COUNT} after {polls} polls"
        )
