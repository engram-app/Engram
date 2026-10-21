"""Unit tests for helpers.clerk_browser.clerk_sign_in_url (no stack needed)."""

from __future__ import annotations

import json
from urllib.parse import parse_qs, urlsplit

import pytest
import requests

import helpers.clerk_browser as cb
from helpers.clerk_browser import clerk_sign_in_url


def _resp(status_code: int, body: dict) -> requests.Response:
    r = requests.Response()
    r.status_code = status_code
    r._content = json.dumps(body).encode()
    return r


class _Session:
    def __init__(self, responses):
        self.responses = list(responses)
        self.calls = []

    def post(self, url, json=None, timeout=None):
        self.calls.append((url, json))
        return self.responses.pop(0)


class _Client:
    base_url = "https://api.clerk.dev/v1"

    def __init__(self, *responses):
        self.session = _Session(responses)


def test_url_shape_and_token_request():
    client = _Client(_resp(200, {"token": "tok_123"}))
    url = clerk_sign_in_url(client, "user_1", "http://app.test", "/link?code=ABCD-EFGH")

    assert url.startswith("http://app.test/sign-in?__clerk_ticket=tok_123&redirect_url=")
    q = parse_qs(urlsplit(url).query)
    assert q["__clerk_ticket"] == ["tok_123"]
    assert q["redirect_url"] == ["http://app.test/link?code=ABCD-EFGH"]
    # The SPA hands Clerk `return_to` as forceRedirectUrl, which wins over redirect_url.
    assert q["return_to"] == ["/link?code=ABCD-EFGH"]
    assert client.session.calls == [
        ("https://api.clerk.dev/v1/sign_in_tokens", {"user_id": "user_1", "expires_in_seconds": 300})
    ]


def test_redirect_is_fully_quoted():
    client = _Client(_resp(200, {"token": "t"}))
    url = clerk_sign_in_url(client, "u", "http://app.test", "/link?code=A B&x=1")
    query = urlsplit(url).query
    # `&`, `?`, `=` and spaces inside the redirect must not leak as top-level params.
    assert "x=1" not in query.split("&")
    assert set(parse_qs(query)) == {"__clerk_ticket", "redirect_url", "return_to"}
    assert parse_qs(query)["redirect_url"] == ["http://app.test/link?code=A B&x=1"]


def test_retries_eventual_consistency_404(monkeypatch):
    monkeypatch.setattr(cb.time, "sleep", lambda _s: None)
    not_found = _resp(404, {"errors": [{"code": "resource_not_found"}]})
    client = _Client(not_found, not_found, _resp(200, {"token": "late"}))
    url = clerk_sign_in_url(client, "u", "http://app.test", "/link")
    assert "__clerk_ticket=late" in url
    assert len(client.session.calls) == 3


def test_non_json_404_raises_http_error():
    r = requests.Response()
    r.status_code = 404
    r._content = b"<html>Not Found</html>"
    client = _Client(r)
    with pytest.raises(requests.HTTPError):
        clerk_sign_in_url(client, "u", "http://app.test", "/link")
    assert len(client.session.calls) == 1


def test_other_errors_raise_immediately():
    client = _Client(_resp(422, {"errors": [{"code": "form_param_missing"}]}))
    with pytest.raises(requests.HTTPError):
        clerk_sign_in_url(client, "u", "http://app.test", "/link")
    assert len(client.session.calls) == 1
