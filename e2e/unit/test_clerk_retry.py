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
            return session_responses.pop(0)
        assert url.endswith("/tokens")
        calls["token_urls"].append(url)
        return token_responses.pop(0)

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
        token_responses=[
            _resp(404, {"errors": [{"code": "resource_not_found"}]}),
            _resp(200, {"jwt": "jwt_ok"}),
        ],
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
        session_responses=[_resp(200, {"id": "sess_a"}), _resp(200, {"id": "sess_b"})],
        token_responses=[
            _resp(404, {"errors": [{"code": "resource_not_found"}]}),
            _resp(404, {"errors": [{"code": "resource_not_found"}]}),
        ],
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


def test_token_mint_plain_404_fails_fast_no_recreate(
    monkeypatch: pytest.MonkeyPatch, clock: _FakeClock
) -> None:
    """A 404 Clerk does NOT attribute to the session (no resource_not_found
    code — e.g. a path/config regression) must fail on the first attempt:
    no session recreate, no extra mint against the rate-limited e2e app."""
    client, calls = _mint_client(
        monkeypatch,
        session_responses=[_resp(200, {"id": "sess_a"})],
        token_responses=[_resp(404, {"errors": [{"code": "not_our_session"}]})],
    )

    with pytest.raises(requests.HTTPError):
        client.create_session_token("user_404")

    assert calls["sessions"] == 1
    assert len(calls["token_urls"]) == 1


# --- named quota failures ---------------------------------------------------
# Run 39329248754 errored 13 tests on POST /v1/users with a bare HTTPError,
# indistinguishable from a product bug. Quota/limit failures must be named.
# Real observed non-quota codes: 400 username_exists, 422 form_param_format_invalid.


def _create_client(monkeypatch: pytest.MonkeyPatch, resp: requests.Response) -> ClerkClient:
    client = ClerkClient("sk_test_fake")
    monkeypatch.setattr(client.session, "post", lambda url, **_kw: resp)
    return client


def test_429_after_retries_is_clerk_quota(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _create_client(monkeypatch, _resp(429, {"errors": [{"code": "rate_limit_exceeded"}]}))

    with pytest.raises(clerk_mod.ClerkQuotaError, match=r"^Clerk quota: .*429"):
        client.create_user("a@example.com", "pw")


def test_422_user_limit_is_clerk_quota(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _create_client(monkeypatch, _resp(422, {"errors": [{"code": "user_quota_exceeded"}]}))

    with pytest.raises(clerk_mod.ClerkQuotaError, match=r"Clerk quota: .*422.*user_quota_exceeded"):
        client.create_user("a@example.com", "pw")


def test_400_limit_code_is_clerk_quota(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _create_client(monkeypatch, _resp(400, {"errors": [{"code": "resource_limit_reached"}]}))

    with pytest.raises(clerk_mod.ClerkQuotaError):
        client.create_user("a@example.com", "pw")


def test_422_identifier_taken_still_reuses_user(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _create_client(monkeypatch, _resp(422, {"errors": [{"code": "form_identifier_exists"}]}))
    monkeypatch.setattr(client, "find_user_by_email", lambda email: "user_existing")

    assert client.create_user("a@example.com", "pw") == "user_existing"
    assert "user_existing" in client.created_user_ids


def test_other_400_is_http_error(monkeypatch: pytest.MonkeyPatch) -> None:
    client = _create_client(monkeypatch, _resp(400, {"errors": [{"code": "username_exists"}]}))

    with pytest.raises(requests.HTTPError) as exc:
        client.create_user("a@example.com", "pw")
    assert not isinstance(exc.value, clerk_mod.ClerkQuotaError)


# --- username derivation ------------------------------------------------------
# Run 39329248754: 400 username_exists when emails shared a base before "+".


def _posted_username(monkeypatch: pytest.MonkeyPatch, email: str) -> str:
    client = ClerkClient("sk_test_fake")
    sent: dict = {}

    def fake_post(url: str, **kw: object) -> requests.Response:
        if url.endswith("/users"):
            sent.update(kw["json"])  # type: ignore[arg-type]
            return _resp(200, {"id": "user_x"})
        return _resp(200, {"id": "sess"})

    monkeypatch.setattr(client.session, "post", fake_post)
    client.create_user(email, "pw")
    return sent["username"]


def test_usernames_differ_for_emails_differing_after_plus(monkeypatch: pytest.MonkeyPatch) -> None:
    a = _posted_username(monkeypatch, "same+one@example.com")
    b = _posted_username(monkeypatch, "same+two@example.com")
    assert a != b


def test_username_is_clerk_valid_for_long_and_odd_emails(monkeypatch: pytest.MonkeyPatch) -> None:
    import re

    for email in (
        "e2e-vacc-u1-2c97b0-20261016082322730191r38871097532je2e-clerkw1+clerk_test@example.com",
        "Weird.Name!#$@Example.com",
        "x" * 200 + "@example.com",
    ):
        u = _posted_username(monkeypatch, email)
        assert re.fullmatch(r"[a-z0-9_-]{1,64}", u), u


def test_username_is_stable_for_same_email(monkeypatch: pytest.MonkeyPatch) -> None:
    e = "stable+tag@example.com"
    assert _posted_username(monkeypatch, e) == _posted_username(monkeypatch, e)


# --- shared e2e email builder -------------------------------------------------
# Clerk 422 form_param_format_invalid (param email_address) on local parts > 64.

_LONG_TS = "20261016082322730191r389999999999j" + "e2e-clerk" + "w12"  # 12-digit run id


def test_e2e_email_local_part_within_64() -> None:
    for label in ("sync", "iso", "onboarding-envelope", "vacc-u1-2c97b0"):
        email = clerk_mod.e2e_email(label, _LONG_TS)
        assert len(email.split("@")[0]) <= 64, email


def test_e2e_email_unique_per_parts() -> None:
    a = clerk_mod.e2e_email("sync", "20261016082322730191r1j1w0")
    b = clerk_mod.e2e_email("sync", "20261016082322730192r1j1w0")
    c = clerk_mod.e2e_email("iso", "20261016082322730191r1j1w0")
    assert len({a, b, c}) == 3


def test_e2e_email_stays_inside_reaper_and_sweep_patterns() -> None:
    from helpers.clerk_constants import is_e2e_clerk_email

    email = clerk_mod.e2e_email("onboarding-envelope", _LONG_TS)
    assert is_e2e_clerk_email(email)
    assert email.endswith(f"{_LONG_TS}+clerk_test@example.com")  # w{N}/r..j.. scoping intact


def test_e2e_email_raises_when_ts_alone_cannot_fit() -> None:
    with pytest.raises(ValueError):
        clerk_mod.e2e_email("x", "9" * 80)
