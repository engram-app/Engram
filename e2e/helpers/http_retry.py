"""Retry policy for e2e HTTP clients that never replays a mutation.

urllib3 retries a read timeout by default, and a read timeout means the server
got the request and may have finished it. Replaying a DELETE or POST then
asserts on the post-success state: #2182, where `DELETE /api/me` took 10 s,
was re-sent, and the replay got 410.

`retry()` keeps connect retries for every method (the request never reached
the server) and status retries only for idempotent methods, and never retries
a read error.
"""

from __future__ import annotations

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

IDEMPOTENT_METHODS = frozenset({"GET", "HEAD", "PUT", "OPTIONS"})


def retry(**overrides) -> Retry:
    """A `Retry` with read retries off. Overrides may widen `allowed_methods`
    for a server that rejects before processing (Clerk's 429), not `read`."""
    if "read" in overrides:
        raise ValueError("read retries replay requests the server already got")
    opts = {
        "total": 3,
        "backoff_factor": 0.2,
        "status_forcelist": (502, 503, 504),
        "allowed_methods": IDEMPOTENT_METHODS,
        "raise_on_status": False,
    }
    opts.update(overrides)
    return Retry(read=0, **opts)


class RetryClient:
    """Fresh `requests.Session` per call, with `retry()` mounted.

    A shared Session persists cookies across calls, which breaks the refresh
    tests: a rotated cookie from the session jar would override the per-call
    ``cookies=`` kwarg. New Session per call = empty jar, so the test's
    explicit cookies (or absence of them) reach the server verbatim.
    """

    def _session(self) -> requests.Session:
        s = requests.Session()
        adapter = HTTPAdapter(max_retries=retry())
        s.mount("http://", adapter)
        s.mount("https://", adapter)
        return s

    def get(self, url, **kw):
        return self._session().get(url, **kw)

    def post(self, url, **kw):
        return self._session().post(url, **kw)

    def put(self, url, **kw):
        return self._session().put(url, **kw)

    def patch(self, url, **kw):
        return self._session().patch(url, **kw)

    def delete(self, url, **kw):
        return self._session().delete(url, **kw)
