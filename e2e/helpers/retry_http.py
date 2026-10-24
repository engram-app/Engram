"""Shared HTTP client for the api_only e2e tests: transient-failure retries
that never replay a non-idempotent request.

urllib3's ``Retry`` replays a request after a READ timeout or a retryable
status only for methods in ``allowed_methods``. A read timeout means the
server may already have processed the request, so replaying a DELETE /me
landed on an already-deleted account and failed with 410 ``account_deleted``
(#2182). Only idempotent reads are replayed. Connect errors are still retried
for every method: the request never reached the server.
"""

import requests
from requests.adapters import HTTPAdapter
from urllib3.util.retry import Retry

IDEMPOTENT_METHODS = frozenset({"GET", "HEAD", "OPTIONS"})

RETRY = Retry(
    total=3,
    backoff_factor=0.2,
    status_forcelist=(502, 503, 504),
    allowed_methods=IDEMPOTENT_METHODS,
    raise_on_status=False,
)


class RetryClient:
    """Fresh ``requests.Session`` per call.

    A shared Session persists cookies across calls, which breaks the refresh
    tests: a rotated cookie from the session jar would override the per-call
    ``cookies=`` kwarg. New Session per call = empty jar, so the test's
    explicit cookies (or absence of them) reach the server verbatim.
    """

    def _session(self) -> requests.Session:
        s = requests.Session()
        adapter = HTTPAdapter(max_retries=RETRY)
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


http = RetryClient()
