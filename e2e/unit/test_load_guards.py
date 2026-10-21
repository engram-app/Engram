"""Load-sim safety guards: never aim at prod, never outspend the cap.

Review of the staging traffic simulator (#2101): nothing stopped a run against
prod, and the spend guard compared tokens only after they were spent.
"""

from __future__ import annotations

import threading

import pytest

from load.guards import SpendGuard, TargetRefused, check_clerk_key, check_target


@pytest.mark.parametrize(
    "api",
    [
        "https://staging.engram.page/api",
        "http://10.0.20.214:8000/api",
        "http://10.0.20.214:8001/api",
        "http://localhost:4000/api",
        "http://127.0.0.1:8100/api",
    ],
)
def test_staging_hosts_pass(api):
    check_target(api, allow_any_host=False)


@pytest.mark.parametrize(
    "api",
    [
        "https://app.engram.page/api",
        "https://api.engram.page/api",
        "https://mcp.engram.page/api",
        "https://staging.engram.page.evil.com/api",
        "https://evil.com/staging.engram.page/api",
        "ftp://staging.engram.page/api",
        "",
        "staging.engram.page",
    ],
)
def test_other_hosts_refused(api):
    with pytest.raises(TargetRefused):
        check_target(api, allow_any_host=False)


def test_override_admits_any_http_host():
    check_target("https://app.engram.page/api", allow_any_host=True)


def test_override_still_needs_a_url():
    with pytest.raises(TargetRefused):
        check_target("not a url", allow_any_host=True)


def test_live_clerk_key_refused():
    with pytest.raises(TargetRefused):
        check_clerk_key("sk_live_abc")


@pytest.mark.parametrize("key", ["", "   "])
def test_missing_clerk_key_refused(key):
    with pytest.raises(TargetRefused):
        check_clerk_key(key)


def test_test_clerk_key_passes():
    check_clerk_key("sk_test_abc")


def test_spend_guard_refuses_past_cap():
    g = SpendGuard(100)
    assert g.take(60)
    assert g.take(40)
    assert not g.take(1)
    assert g.spent == 100
    assert g.refused == 1


def test_spend_guard_refusal_spends_nothing():
    g = SpendGuard(10)
    assert not g.take(11)
    assert g.spent == 0
    assert g.take(10)


def test_spend_guard_zero_tokens_always_ok():
    g = SpendGuard(0)
    assert g.take(0)
    assert not g.take(1)


def test_spend_guard_is_thread_safe():
    g = SpendGuard(1000)
    ok = []
    lock = threading.Lock()

    def worker():
        for _ in range(100):
            if g.take(1):
                with lock:
                    ok.append(1)

    ts = [threading.Thread(target=worker) for _ in range(20)]
    for t in ts:
        t.start()
    for t in ts:
        t.join()
    assert len(ok) == 1000
    assert g.spent == 1000
