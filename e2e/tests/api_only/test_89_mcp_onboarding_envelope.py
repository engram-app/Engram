"""E2E test 89: an un-onboarded MCP call gets a refusal it can actually read.

A user who reaches Engram through an MCP client's OAuth flow can finish the
grant with no terms accepted, no plan and no vault. Every tool call then hits
`RequireOnboarding` and 403s. That part is correct. What was not correct is the
SHAPE of the refusal: the gate plugs halt inside the `:authed_api` pipeline,
long before `McpController` runs, so the body went out as the flat REST map
every other API route gets. That is not a JSON-RPC response, so MCP clients
surface a bare "HTTP 403" and drop the body — remedy included. A real user
burned five hours and twelve DCR registrations against exactly that wall
(#1666).

Unit tests cover `McpErrorEnvelope` in isolation and through a synthetic
pipeline. Neither can prove the plug is actually INSTALLED on the MCP scope of
a booted server, in the right order relative to the seven plugs it wraps. That
is what this test is for.

Deliberately NOT using `provision_oauth_tokens`: it pre-completes onboarding
(and could not avoid it anyway — `POST /api/auth/device/authorize` carries
`RequireOnboarding` itself, so device tokens are unobtainable before
onboarding). A raw Clerk session token reaches the same gate by the same path,
which is what this test needs.

This is also the class of bug the e2e harness structurally cannot catch:
`frontend/e2e/global-setup.ts`, `helpers/oauth.py` and `helpers/clerk_auth.py`
all pre-complete onboarding before the first assertion, so no other test in
either suite has ever been an un-onboarded user.
"""

from __future__ import annotations

import logging
import os
import secrets
from datetime import datetime

import pytest
import requests

from helpers.clerk import ClerkClient

logger = logging.getLogger(__name__)

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
CLERK_SECRET = os.environ.get("E2E_CLERK_SECRET_KEY", "")

pytestmark = pytest.mark.skipif(
    not CLERK_SECRET,
    reason="E2E_CLERK_SECRET_KEY not set — Clerk auth required for the onboarding envelope test",
)


def test_mcp_onboarding_refusal_is_jsonrpc_shaped():
    clerk = ClerkClient(CLERK_SECRET)
    ts = datetime.now().strftime("%Y%m%d%H%M%S%f")
    email = f"e2e-onboarding-envelope-{ts}+clerk_test@example.com"

    clerk_user_id = clerk.create_user(email, secrets.token_urlsafe(32))
    try:
        # No onboarding call of any kind. That is the whole point.
        token = clerk.create_session_token(clerk_user_id)
        headers = {"Authorization": f"Bearer {token}"}

        resp = requests.post(
            f"{API_URL}/mcp",
            json={
                "jsonrpc": "2.0",
                "id": 4242,
                "method": "tools/call",
                "params": {"name": "list_folders", "arguments": {}},
            },
            headers=headers,
            timeout=15,
        )

        # Status is unchanged by the envelope — clients that key off it, and
        # every existing assertion, still see a refusal.
        assert resp.status_code == 403, (
            f"an un-onboarded MCP call must be refused; got {resp.status_code}: "
            f"{resp.text[:300]}"
        )

        body = resp.json()
        assert body.get("jsonrpc") == "2.0", (
            f"the refusal must be a JSON-RPC response or an MCP client cannot read "
            f"it at all; got {body}"
        )
        assert body.get("id") == 4242, (
            f"the request's own id must come back so a client can correlate; got {body}"
        )

        error = body.get("error") or {}
        assert isinstance(error.get("code"), int), f"missing JSON-RPC error code: {body}"

        # The sentence is the entire point of the change: a human has to learn
        # what to do from it, without reading field names.
        message = error.get("message") or ""
        assert isinstance(message, str) and message.strip(), f"no readable message: {body}"
        assert "onboard" in message.lower(), (
            f"the message must say where to go, not just that something failed; got {message!r}"
        )

        # Machine-readable detail survives one level down, so a client that DOES
        # parse our fields keeps everything it had before.
        data = error.get("data") or {}
        assert data.get("error") == "onboarding_required", (
            f"the original reason must survive under error.data; got {body}"
        )
        assert isinstance(data.get("resume_url"), str) and data["resume_url"].startswith(
            "http"
        ), f"resume_url must be absolute — a path is unresolvable to an MCP client; got {data}"

        # Scoping guard. The envelope is a property of the MCP resource; REST
        # callers (SPA, plugin) read `error` off the top level and must be
        # untouched by it.
        rest = requests.get(f"{API_URL}/notes", headers=headers, timeout=15)
        assert rest.status_code == 403, f"REST should refuse too; got {rest.status_code}"
        rest_body = rest.json()
        assert rest_body.get("error") == "onboarding_required", (
            f"REST refusals must keep their flat shape; got {rest_body}"
        )
        assert "jsonrpc" not in rest_body, (
            f"the JSON-RPC envelope must not leak onto REST routes; got {rest_body}"
        )
    finally:
        clerk.delete_user(clerk_user_id)
