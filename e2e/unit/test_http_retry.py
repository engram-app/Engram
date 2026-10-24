"""helpers.http_retry never replays a request the server already received.

Regression lock for #2182: `DELETE /api/me` outlived the client's read
timeout, urllib3 re-sent it, and the replay saw the deleted account (410).
A real local HTTP server, no CI stack.
"""

from __future__ import annotations

import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import pytest
import requests

from helpers.http_retry import RetryClient, retry


class _Server:
    def __init__(self, delay: float = 0.0, status: int = 200) -> None:
        self.hits: list[str] = []
        server = self

        class Handler(BaseHTTPRequestHandler):
            def _handle(self) -> None:
                server.hits.append(self.command)
                time.sleep(server.delay)
                self.send_response(server.status)
                self.send_header("Content-Length", "0")
                self.end_headers()

            do_GET = do_POST = do_DELETE = do_PATCH = do_PUT = _handle

            def log_message(self, *_args) -> None:
                pass

        self.delay = delay
        self.status = status
        self.httpd = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
        self.url = f"http://127.0.0.1:{self.httpd.server_port}/x"
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()

    def close(self) -> None:
        self.httpd.shutdown()
        self.httpd.server_close()


@pytest.fixture()
def server():
    created: list[_Server] = []

    def make(**kw) -> _Server:
        s = _Server(**kw)
        created.append(s)
        return s

    yield make
    for s in created:
        s.close()


@pytest.mark.parametrize("method", ["delete", "post", "patch", "get"])
def test_a_read_timeout_is_never_replayed(server, method):
    s = server(delay=0.5)

    with pytest.raises(requests.exceptions.RequestException):
        getattr(RetryClient(), method)(s.url, timeout=0.1)

    time.sleep(0.6)  # let any replay land before counting
    assert s.hits == [method.upper()]


def test_a_503_retries_an_idempotent_method(server):
    s = server(status=503)
    RetryClient().get(s.url, timeout=2)
    assert len(s.hits) == 4  # first try + total=3


def test_a_503_does_not_retry_a_mutation(server):
    s = server(status=503)
    RetryClient().delete(s.url, timeout=2)
    assert s.hits == ["DELETE"]


def test_read_retries_cannot_be_turned_back_on():
    with pytest.raises(ValueError):
        retry(read=2)
