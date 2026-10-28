"""Users created by ANY ClerkClient must be reaped by cleanup_tracked, and a
near-full instance must fail fast. No network: the session is stubbed."""

import pytest

from helpers.clerk import ClerkClient, ClerkQuotaError


class _Resp:
    def __init__(self, status=200, body=None):
        self.status_code, self._body = status, body or {}

    def raise_for_status(self):
        pass

    def json(self):
        return self._body


class _Session:
    def __init__(self, count=0):
        self.deleted, self.count = [], count

    def delete(self, url, timeout=None):
        self.deleted.append(url.rsplit("/", 1)[1])
        return _Resp()

    def get(self, url, timeout=None, **kw):
        return _Resp(body={"total_count": self.count})


def _client(count=0):
    c = ClerkClient("sk_test_fake")
    c.session = _Session(count)
    return c


@pytest.fixture(autouse=True)
def _clean_registry():
    ClerkClient.created_user_ids.clear()
    yield
    ClerkClient.created_user_ids.clear()


def test_cleanup_tracked_covers_users_from_other_instances():
    test_local, shared = _client(), _client()
    test_local.created_user_ids.add("user_leaky")  # as create_user does
    shared.cleanup_tracked()
    assert shared.session.deleted == ["user_leaky"]
    assert not ClerkClient.created_user_ids


def test_quota_preflight_fails_fast_when_nearly_full():
    with pytest.raises(ClerkQuotaError, match="97/100.*cleanup_clerk_users.py"):
        _client(97).assert_quota_headroom()
    _client(10).assert_quota_headroom()


class _BadCountSession(_Session):
    def __init__(self, resp=None, exc=None):
        super().__init__()
        self.resp, self.exc = resp, exc

    def get(self, url, timeout=None, **kw):
        if self.exc:
            raise self.exc
        return self.resp


def test_quota_preflight_warns_and_continues_on_count_errors():
    import requests

    for kw in (
        {"exc": requests.HTTPError("429")},
        {"resp": _Resp(body={})},  # missing total_count
        {"resp": _Resp(body={"total_count": "97"})},  # wrong type
    ):
        c = _client()
        c.session = _BadCountSession(**kw)
        c.assert_quota_headroom()  # must not raise


def test_live_key_refused():
    with pytest.raises(ValueError, match="sk_test_"):
        ClerkClient("sk_live_abc")
