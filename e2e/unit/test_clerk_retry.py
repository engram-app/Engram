"""Unit tests for helpers.clerk session-create retry — no CI stack needed.

Regression lock for issue #869: Clerk's POST /sessions is eventually
consistent and NON-monotonic vs POST /users — the create_user readiness
probe can succeed and a later create_session still 404 for several seconds
(observed ~6s in degraded periods). The backstop retry must be wall-clock
budgeted, not a handful of tight attempts.

These tests fake the HTTP layer and the clock; they run without any stack.
"""

from __future__ import annotations

import json

import pytest
import requests

import helpers.clerk as clerk_mod
from helpers.clerk import ClerkClient


def _resp(status_code: int, body: dict) -> requests.Response:
    r = requests.Response()
    r.status_code = status_code
    r._content = json.dumps(body).encode()
    return r


def _not_found() -> requests.Response:
    return _resp(404, {"errors": [{"code": "resource_not_found"}]})


class _FakeClock:
    """Deterministic time.monotonic/time.sleep pair: sleeping advances the clock."""

    def __init__(self) -> None:
        self.now = 0.0
        self.slept: list[float] = []

    def monotonic(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.slept.append(seconds)
        self.now += seconds


@pytest.fixture()
def clock(monkeypatch: pytest.MonkeyPatch) -> _FakeClock:
    c = _FakeClock()
    monkeypatch.setattr(clerk_mod.time, "monotonic", c.monotonic)
    monkeypatch.setattr(clerk_mod.time, "sleep", c.sleep)
    return c


def _client_with_responses(
    monkeypatch: pytest.MonkeyPatch, responses: list[requests.Response]
) -> tuple[ClerkClient, list[int]]:
    client = ClerkClient("sk_test_fake")
    calls: list[int] = []

    def fake_post(url: str, **_kwargs: object) -> requests.Response:
        assert url.endswith("/sessions")
        calls.append(1)
        return responses.pop(0) if len(responses) > 1 else responses[0]

    monkeypatch.setattr(client.session, "post", fake_post)
    return client, calls


def test_session_create_survives_slow_propagation(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    """Six consecutive 404s (beyond the old 5-attempt cap) then success."""
    responses = [_not_found() for _ in range(6)] + [_resp(200, {"id": "sess_ok"})]
    client, calls = _client_with_responses(monkeypatch, responses)

    session_id = client._create_session_with_retry("user_fresh")

    assert session_id == "sess_ok"
    assert len(calls) == 7
    # All waiting stayed within the wall-clock budget.
    assert sum(clock.slept) <= clerk_mod._SESSION_CREATE_MAX_WAIT_SECONDS


def test_session_create_gives_up_after_wall_clock_budget(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    """Persistent 404 raises HTTPError once the budget is exhausted, not before."""
    client, calls = _client_with_responses(monkeypatch, [_not_found()])

    with pytest.raises(requests.HTTPError):
        client._create_session_with_retry("user_never")

    assert sum(clock.slept) >= clerk_mod._SESSION_CREATE_MAX_WAIT_SECONDS * 0.8
    assert len(calls) >= 6  # kept trying throughout the window


def test_session_create_raises_immediately_on_non_404(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    client, calls = _client_with_responses(
        monkeypatch, [_resp(500, {"errors": [{"code": "internal"}]})]
    )

    with pytest.raises(requests.HTTPError):
        client._create_session_with_retry("user_500")

    assert len(calls) == 1
    assert clock.slept == []


# --- token-mint 404 retry (#978) -------------------------------------------
# A Clerk session id can vanish (or not yet be visible) between POST /sessions
# and POST /sessions/{id}/tokens — main run 28987167162 ERROR'd a whole module
# on a 404 there. A 404 on the tokens endpoint is definitively "session gone",
# so create_session_token must recreate the session and retry ONCE.


def _mint_client(
    monkeypatch: pytest.MonkeyPatch,
    session_responses: list[requests.Response],
    token_responses: list[requests.Response],
) -> tuple[ClerkClient, dict]:
    client = ClerkClient("sk_test_fake")
    calls: dict = {"sessions": 0, "token_urls": []}

    def fake_post(url: str, **_kwargs: object) -> requests.Response:
        if url.endswith("/sessions"):
            calls["sessions"] += 1
            return (
                session_responses.pop(0)
                if len(session_responses) > 1
                else session_responses[0]
            )
        assert url.endswith("/tokens")
        calls["token_urls"].append(url)
        return (
            token_responses.pop(0) if len(token_responses) > 1 else token_responses[0]
        )

    monkeypatch.setattr(client.session, "post", fake_post)
    return client, calls


def test_token_mint_404_recreates_session_and_retries_once(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    client, calls = _mint_client(
        monkeypatch,
        session_responses=[
            _resp(200, {"id": "sess_stale"}),
            _resp(200, {"id": "sess_fresh"}),
        ],
        token_responses=[_resp(404, {"errors": []}), _resp(200, {"jwt": "jwt_ok"})],
    )

    token = client.create_session_token("user_x")

    assert token == "jwt_ok"
    assert calls["sessions"] == 2
    # The retry minted from the RECREATED session, not the stale id.
    assert calls["token_urls"][0].endswith("/sessions/sess_stale/tokens")
    assert calls["token_urls"][1].endswith("/sessions/sess_fresh/tokens")


def test_token_mint_404_twice_raises(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    client, calls = _mint_client(
        monkeypatch,
        session_responses=[_resp(200, {"id": "sess_a"})],
        token_responses=[_resp(404, {"errors": []})],
    )

    with pytest.raises(requests.HTTPError):
        client.create_session_token("user_gone")

    assert calls["sessions"] == 2  # exactly one recreate, no loop
    assert len(calls["token_urls"]) == 2


def test_token_mint_non_404_raises_immediately(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    client, calls = _mint_client(
        monkeypatch,
        session_responses=[_resp(200, {"id": "sess_a"})],
        token_responses=[_resp(500, {"errors": [{"code": "internal"}]})],
    )

    with pytest.raises(requests.HTTPError):
        client.create_session_token("user_500")

    assert calls["sessions"] == 1
    assert len(calls["token_urls"]) == 1
