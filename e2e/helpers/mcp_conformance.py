"""Drive the MCPJam conformance CLI through our Clerk-gated consent screen.

WHY THIS EXISTS
---------------
`oauth conformance --auth-mode headless` cannot finish against us: our
authorization endpoint requires a Clerk session, so the run stops at
`received_authorization_code` and everything past it — the token exchange, the
authenticated MCP call, and the `--conformance-checks` negative checks — never
grades. That is a harness limitation, not a product one, and it is the single
wall behind every remaining coverage gap.

It does NOT need browser automation. `test_71_connections` already completes
the same flow over HTTP: `POST /api/oauth/authorize/consent` with a Clerk JWT
returns `{redirect_uri: "...?code=..."}`. This module puts that between the
CLI and its own loopback listener.

THE ONE THING THAT MATTERS
--------------------------
Reuse the CLI's OWN `client_id`, `code_challenge`, `state` and `redirect_uri`,
parsed from the authorize URL it prints. The CLI holds the PKCE *verifier* and
will present it at the token endpoint; minting our own challenge here would
produce a code the CLI cannot redeem, and the failure would surface at
`token_request` looking like a server bug.
"""
from __future__ import annotations

import logging
import re
import subprocess
import threading
from urllib.parse import parse_qs, urlparse

import requests

logger = logging.getLogger(__name__)

# The CLI prints the consent URL to stderr under --print-url. Match a URL
# containing an authorize path rather than the first URL on the line, since the
# surrounding prose also carries links.
_AUTHORIZE_RE = re.compile(r"(https?://\S*/oauth/authorize\?\S+)")


def extract_authorize_url(line: str) -> str | None:
    match = _AUTHORIZE_RE.search(line)
    return match.group(1).rstrip('"\'') if match else None


def approve(
    authorize_url: str,
    jwt_token: str,
    api_url: str,
    *,
    vault_choice: str = "vault:*",
    vault_ids: list[str] | None = None,
):
    """Approve the CLI's pending authorization and hand the code back to it.

    Returns the redirect URI the server issued, after it has been delivered to
    the CLI's loopback listener.

    `vault_ids` scopes the grant to exactly those vaults, matching what the
    consent screen posts today. `vault_choice` is the single-vault
    predecessor and stays the default so the back-compat clause keeps its
    coverage; the server prefers `vault_ids` when both are sent, so only one
    goes on the wire.
    """
    params = parse_qs(urlparse(authorize_url).query)

    def one(key: str) -> str:
        values = params.get(key)
        # A missing parameter means the CLI changed its authorize request. Fail
        # loudly here rather than send a half-formed consent the server will
        # reject with a message about OUR payload.
        assert values, f"authorize URL missing `{key}`: {authorize_url}"
        return values[0]

    payload = {
        "client_id": one("client_id"),
        "state": one("state"),
        "code_challenge": one("code_challenge"),
        "code_challenge_method": params.get("code_challenge_method", ["S256"])[0],
        "redirect_uri": one("redirect_uri"),
        "scope": params.get("scope", ["mcp"])[0],
        "response_type": "code",
    }
    if vault_ids is None:
        payload["vault_choice"] = vault_choice
    else:
        payload["vault_ids"] = vault_ids

    resp = requests.post(
        f"{api_url}/oauth/authorize/consent",
        json=payload,
        headers={"Authorization": f"Bearer {jwt_token}"},
        timeout=15,
    )
    resp.raise_for_status()
    redirect_uri = resp.json()["redirect_uri"]

    # Deliver the code to the loopback server the CLI is blocking on. It
    # answers and exits, so a connection error after the handoff is normal —
    # but a failure to CONNECT means the CLI was not listening, which is a real
    # problem worth surfacing.
    try:
        requests.get(redirect_uri, timeout=15, allow_redirects=False)
    except requests.exceptions.ConnectionError as exc:
        raise AssertionError(
            f"could not deliver the code to the CLI's loopback listener at "
            f"{redirect_uri} — is it running with --print-url? ({exc})"
        ) from exc

    return redirect_uri


def run_with_consent(argv: list[str], jwt_token: str, api_url: str, *, timeout: int = 240):
    """Run the CLI, approving consent as soon as it asks. Returns CompletedProcess."""
    proc = subprocess.Popen(
        argv,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        bufsize=1,
    )

    approved: list[str] = []
    failures: list[BaseException] = []

    def watch_stderr():
        # Read line-by-line rather than .communicate(): the CLI blocks waiting
        # for the redirect, so buffering until exit would deadlock.
        for line in proc.stderr:
            logger.info("[cli] %s", line.rstrip())
            if approved:
                continue
            url = extract_authorize_url(line)
            if url:
                try:
                    approved.append(approve(url, jwt_token, api_url))
                except BaseException as exc:  # surfaced after join
                    failures.append(exc)
                    proc.kill()

    watcher = threading.Thread(target=watch_stderr, daemon=True)
    watcher.start()

    stdout, _ = proc.communicate(timeout=timeout)
    watcher.join(timeout=10)

    if failures:
        raise failures[0]

    assert approved, "CLI never printed an authorize URL — consent was never driven"
    return subprocess.CompletedProcess(argv, proc.returncode, stdout, "")
