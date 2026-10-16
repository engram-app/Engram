"""Per-vault access levels (#174 OAuth grants, #332 API keys), real stack.

Every credential here is minted the way a real client mints it: DCR ->
consent -> /oauth/token for OAuth, POST /api/connections/pat for keys. The
unit suite (test/engram_web/vault_access_levels_test.exs) proves the rules;
this file proves they hold through the deployed release, its plugs and its
token chain.

Provider-agnostic: runs in BOTH api_only lanes (e2e-clerk and e2e-crdt's
local-auth step). Each test provisions its own user and vaults, so nothing is
counted across the session-scoped shared vault
(docs/context/e2e-session-vault-scoping-trap.md).

A `none` vault and an unknown vault are refused the same way so the response
is not an existence oracle; that status is moving (403 -> 404), so a none
vault is asserted as "refused (403/404), no note content", never one code.
"""
from __future__ import annotations

import base64
import hashlib
import os
import secrets
from datetime import datetime
from urllib.parse import parse_qs, urlparse

import pytest
import requests

from helpers.auth_provider import ClerkAuthProvider
from helpers.billing import grant_test_plan, grant_vault_headroom

API_URL = os.environ.get("ENGRAM_API_URL", "http://localhost:8100/api")
OAUTH_BASE = API_URL[: -len("/api")] if API_URL.endswith("/api") else API_URL.rsplit("/api", 1)[0]
REDIRECT = "http://127.0.0.1:51234/cb"
REFUSED = (403, 404)

_VERIFIER = secrets.token_urlsafe(32)
_CHALLENGE = (
    base64.urlsafe_b64encode(hashlib.sha256(_VERIFIER.encode()).digest()).rstrip(b"=").decode()
)


# ── Users and vaults ─────────────────────────────────────────────────────────


class User:
    """A fresh user. `session()` returns a session bearer (Clerk JWT or local
    access token) for the session-only routes; `legacy_key` is the pre-levels
    `engram_` key provisioning minted."""

    def __init__(self, auth_provider, ts: str):
        self.provider = auth_provider
        # Clerk caps an email's local part at 64 characters, and the session
        # `ts` plus a per-user tag overran it. A fresh timestamp per user is
        # unique on its own, and keeps the `{20 digits}r{run}j{job}w{n}` shape
        # the run sweep matches and age-gates on.
        run_scope = ts[ts.index("r") :]
        now = datetime.now().strftime("%Y%m%d%H%M%S%f")
        self.email = f"e2e-{now}{run_scope}+clerk_test@example.com"
        assert len(self.email.split("@")[0]) <= 64, self.email
        self.password = secrets.token_urlsafe(32)
        self.uid, self.legacy_key = auth_provider.provision_user(self.email, self.password)
        grant_test_plan(self.email)
        grant_vault_headroom(self.email)

    def session(self) -> str:
        if isinstance(self.provider, ClerkAuthProvider):
            return self.provider.clerk_client.create_session_token(self.uid)
        resp = requests.post(
            f"{API_URL}/auth/login",
            json={"email": self.email, "password": self.password},
            timeout=10,
        )
        assert resp.status_code == 200, f"login failed: {resp.status_code} {resp.text}"
        return resp.json()["access_token"]

    def vault(self, name: str) -> str:
        """A new vault holding a.md (its content names the vault)."""
        client_id = f"{name}-{secrets.token_hex(4)}"
        resp = requests.post(
            f"{API_URL}/vaults/register",
            json={"name": client_id, "client_id": client_id},
            headers=_bearer(self.session()),
            timeout=10,
        )
        assert resp.status_code in (200, 201), f"vault create: {resp.status_code} {resp.text}"
        vid = str(resp.json()["id"])
        seeded = rest_write(self.legacy_key, vid, "a.md", f"content of {name}")
        assert seeded.status_code in (200, 201), f"seed: {seeded.status_code} {seeded.text}"
        return vid


@pytest.fixture
def user(auth_provider, ts):
    u = User(auth_provider, ts)
    yield u
    auth_provider.cleanup_user(u.uid)


@pytest.fixture
def other_user(auth_provider, ts):
    u = User(auth_provider, ts)
    yield u
    auth_provider.cleanup_user(u.uid)


# ── HTTP helpers ─────────────────────────────────────────────────────────────


def _bearer(token: str) -> dict:
    return {"Authorization": f"Bearer {token}"}


def rest_write(token: str, vault_id: str, path: str = "rest.md", content: str = "x"):
    return requests.post(
        f"{API_URL}/notes",
        json={"path": path, "content": content, "mtime": 1.0},
        headers={**_bearer(token), "X-Vault-ID": vault_id},
        timeout=10,
    )


def rest_read(token: str, vault_id: str, path: str = "a.md"):
    return requests.get(
        f"{API_URL}/notes/{path}",
        headers={**_bearer(token), "X-Vault-ID": vault_id},
        timeout=10,
    )


def assert_rest_refused(token: str, vault_id: str, label: str):
    resp = rest_read(token, vault_id)
    assert resp.status_code in REFUSED, f"{label}: expected refusal, got {resp.status_code} {resp.text}"
    assert "content of" not in resp.text, f"{label}: refusal leaked note content: {resp.text}"


def assert_read_only(resp, label: str):
    assert resp.status_code == 403, f"{label}: expected 403, got {resp.status_code} {resp.text}"
    assert resp.json().get("error") == "read_only_vault", f"{label}: {resp.text}"


def mcp_call(token: str, name: str, args: dict) -> dict:
    resp = requests.post(
        f"{API_URL}/mcp",
        json={
            "jsonrpc": "2.0",
            "id": 1,
            "method": "tools/call",
            "params": {"name": name, "arguments": args},
        },
        headers=_bearer(token),
        timeout=30,
    )
    assert resp.status_code == 200, f"MCP {name}: {resp.status_code} {resp.text}"
    return resp.json()


def tool_text(body: dict) -> str:
    return " ".join(c.get("text", "") for c in (body.get("result") or {}).get("content", []))


def tool_refusal(body: dict) -> str:
    """A refused tool call is a tool result with isError (MCP spec: tool
    execution errors), not a JSON-RPC error. Returns its text."""
    assert "error" not in body, f"expected a tool result, got protocol error {body['error']}"
    assert body["result"]["isError"] is True, f"expected isError, got {body}"
    return tool_text(body)


def write_refusal_text(body: dict) -> str:
    """Refusal text whichever layer refused: a scope gate (`mcp:read`) answers
    with a JSON-RPC error, a per-vault level with an isError tool result."""
    if "error" in body:
        return body["error"].get("message", "")
    assert body["result"]["isError"] is True, f"write was NOT refused: {body}"
    return tool_text(body)


def listed_vaults(token: str) -> set[str]:
    body = mcp_call(token, "list_vaults", {})
    assert "error" not in body, body
    return {str(v["id"]) for v in body["result"]["structuredContent"]["vaults"]}


# ── OAuth helpers ────────────────────────────────────────────────────────────


def register_client() -> str:
    resp = requests.post(
        f"{OAUTH_BASE}/oauth/register",
        json={
            "client_name": "Vault Levels Tool",
            "software_id": f"vacc-{secrets.token_hex(4)}",
            "redirect_uris": [REDIRECT],
            "grant_types": ["authorization_code", "refresh_token"],
            "response_types": ["code"],
            "token_endpoint_auth_method": "none",
            "kind": "mcp",
        },
        timeout=10,
    )
    assert resp.status_code == 201, f"DCR: {resp.status_code} {resp.text}"
    return resp.json()["client_id"]


def consent(session: str, client_id: str, vault_access: dict, default: str, scope: str = "mcp"):
    return requests.post(
        f"{API_URL}/oauth/authorize/consent",
        json={
            "client_id": client_id,
            "state": secrets.token_urlsafe(8),
            "code_challenge": _CHALLENGE,
            "code_challenge_method": "S256",
            "redirect_uri": REDIRECT,
            "scope": scope,
            "response_type": "code",
            "vault_access": vault_access,
            "default_access": default,
        },
        headers=_bearer(session),
        timeout=10,
    )


def _redirect_query(resp) -> dict:
    assert resp.status_code == 200, f"consent: {resp.status_code} {resp.text}"
    return parse_qs(urlparse(resp.json()["redirect_uri"]).query)


def grant(user: User, vault_access: dict, default: str, scope: str = "mcp") -> tuple[str, dict]:
    """Real DCR -> consent -> token. Returns (client_id, token response)."""
    client_id = register_client()
    query = _redirect_query(consent(user.session(), client_id, vault_access, default, scope))
    assert "code" in query, f"consent did not issue a code: {query}"
    resp = requests.post(
        f"{OAUTH_BASE}/oauth/token",
        json={
            "grant_type": "authorization_code",
            "code": query["code"][0],
            "client_id": client_id,
            "code_verifier": _VERIFIER,
            "redirect_uri": REDIRECT,
        },
        timeout=10,
    )
    assert resp.status_code == 200, f"token exchange: {resp.status_code} {resp.text}"
    return client_id, resp.json()


def refresh(client_id: str, refresh_token: str) -> dict:
    resp = requests.post(
        f"{OAUTH_BASE}/oauth/token",
        json={"grant_type": "refresh_token", "refresh_token": refresh_token, "client_id": client_id},
        timeout=10,
    )
    assert resp.status_code == 200, f"refresh: {resp.status_code} {resp.text}"
    return resp.json()


def connection(user: User, pred) -> dict:
    resp = requests.get(f"{API_URL}/connections", headers=_bearer(user.session()), timeout=10)
    resp.raise_for_status()
    row = next((r for r in resp.json() if pred(r)), None)
    assert row is not None, f"connection not listed: {resp.json()}"
    return row


def patch_oauth(user: User, client_id: str, vault_access: dict, default: str):
    family_id = connection(user, lambda r: r["client_id"] == client_id)["family_id"]
    return requests.patch(
        f"{API_URL}/connections/oauth/{client_id}",
        params={"family_id": family_id},
        json={"vault_access": vault_access, "default_access": default},
        headers=_bearer(user.session()),
        timeout=10,
    )


def patch_pat(user: User, key_id: str, vault_access: dict, default: str):
    return requests.patch(
        f"{API_URL}/connections/pat/{key_id}",
        json={"vault_access": vault_access, "default_access": default},
        headers=_bearer(user.session()),
        timeout=10,
    )


# ── Tests ────────────────────────────────────────────────────────────────────


def test_oauth_grant_enforces_write_read_none_per_vault(user):
    """A=write, B=read, C=none: REST and MCP both honor each level."""
    a, b, c = user.vault("A"), user.vault("B"), user.vault("C")
    _, tokens = grant(user, {a: "write", b: "read", c: "none"}, "none")
    tok = tokens["access_token"]

    # REST
    assert rest_write(tok, a).status_code in (200, 201), "write vault must accept a write"
    assert_read_only(rest_write(tok, b), "REST write on read vault")
    read_b = rest_read(tok, b)
    assert read_b.status_code == 200 and "content of B" in read_b.text, read_b.text
    assert_rest_refused(tok, c, "REST read on none vault")
    # The refused write left nothing behind.
    assert rest_read(user.legacy_key, b, "rest.md").status_code == 404

    # MCP
    refusal = tool_refusal(mcp_call(tok, "write_note", {"vault_id": b, "path": "m.md", "content": "x"}))
    assert "read-only" in refusal, refusal
    assert rest_read(user.legacy_key, b, "m.md").status_code == 404, "refused MCP write landed"
    got = mcp_call(tok, "get_notes", {"vault_id": b, "paths": ["a.md"]})
    assert "error" not in got and "content of B" in tool_text(got), got
    assert not (mcp_call(tok, "write_note", {"vault_id": a, "path": "m.md", "content": "x"})
                ["result"]["isError"]), "MCP write on write vault refused"

    assert listed_vaults(tok) == {a, b}, "list_vaults must show A and B, never C"


def test_vault_created_after_grant_follows_default_access(user):
    a = user.vault("A")
    _, none_default = grant(user, {a: "write"}, "none")
    _, write_default = grant(user, {a: "write"}, "write")
    later = user.vault("Later")

    tok = none_default["access_token"]
    assert_rest_refused(tok, later, "default none, later vault")
    assert later not in listed_vaults(tok)
    assert mcp_call(tok, "get_notes", {"vault_id": later, "paths": ["a.md"]})["result"]["isError"]

    tok = write_default["access_token"]
    assert later in listed_vaults(tok)
    assert rest_write(tok, later).status_code in (200, 201), "default write must reach a later vault"
    assert rest_read(tok, later).status_code == 200


def test_mcp_read_grant_never_writes(user):
    a = user.vault("A")
    client_id, tokens = grant(user, {a: "write"}, "write", scope="mcp:read")
    assert tokens["scope"] == "mcp:read", tokens
    tok = tokens["access_token"]

    assert rest_write(tok, a).status_code == 403, "REST write under mcp:read"
    text = write_refusal_text(mcp_call(tok, "write_note", {"vault_id": a, "path": "m.md", "content": "x"}))
    assert "read-only" in text, text
    for path in ("rest.md", "m.md"):
        assert rest_read(user.legacy_key, a, path).status_code == 404, f"{path} was written"
    assert rest_read(tok, a).status_code == 200, "mcp:read must still read"

    resp = patch_oauth(user, client_id, {a: "write"}, "write")
    assert resp.status_code == 422, f"widening mcp:read to write: {resp.status_code} {resp.text}"
    # And a refresh does not widen it either.
    assert refresh(client_id, tokens["refresh_token"])["scope"] == "mcp:read"


def test_leveled_api_key_and_patch_take_effect_immediately(user):
    a, b, c = user.vault("A"), user.vault("B"), user.vault("C")
    resp = requests.post(
        f"{API_URL}/connections/pat",
        json={"name": "leveled", "vault_access": {a: "read", b: "write"}, "default_access": "none"},
        headers=_bearer(user.session()),
        timeout=10,
    )
    assert resp.status_code == 201, f"leveled key create: {resp.status_code} {resp.text}"
    key, key_id = resp.json()["key"], resp.json()["id"]
    assert key.startswith("engram_lk_"), key

    assert_read_only(rest_write(key, a), "leveled key write on read vault")
    assert rest_read(key, a).status_code == 200
    assert rest_write(key, b).status_code in (200, 201), "leveled key write on write vault"
    assert_rest_refused(key, c, "leveled key, unlisted vault under default none")

    # Narrow: A to none, B to read. The key can now write nowhere, which the
    # account-level gate answers as read_only_grant before any vault check.
    patched = patch_pat(user, key_id, {a: "none", b: "read"}, "none")
    assert patched.status_code == 200, f"PATCH key: {patched.status_code} {patched.text}"
    assert_rest_refused(key, a, "leveled key after narrowing A to none")
    assert rest_read(key, b).status_code == 200
    narrowed = rest_write(key, b, "after.md")
    assert narrowed.status_code == 403 and narrowed.json()["error"] == "read_only_grant", narrowed.text

    # Legacy (pre-levels) key: unchanged behaviour, and not editable.
    assert not user.legacy_key.startswith("engram_lk_")
    assert rest_write(user.legacy_key, a, "legacy.md").status_code in (200, 201)
    legacy_id = connection(
        user, lambda r: r["kind"] == "pat" and r["key_id"] != key_id
    )["key_id"]
    legacy_patch = patch_pat(user, legacy_id, {a: "read"}, "none")
    assert legacy_patch.status_code == 422, f"{legacy_patch.status_code} {legacy_patch.text}"
    assert rest_write(user.legacy_key, a, "legacy2.md").status_code in (200, 201)


def test_narrowing_oauth_grant_hits_issued_token_and_survives_refresh(user):
    a, b, c = user.vault("A"), user.vault("B"), user.vault("C")
    client_id, tokens = grant(user, {a: "write", b: "write", c: "read"}, "none")
    tok = tokens["access_token"]
    assert rest_write(tok, a).status_code in (200, 201)
    assert rest_read(tok, c).status_code == 200

    patched = patch_oauth(user, client_id, {a: "read", b: "write", c: "none"}, "none")
    assert patched.status_code == 200, f"PATCH grant: {patched.status_code} {patched.text}"

    # Same, already-issued token: narrowed at once.
    for label, t in (("issued", tok), ("refreshed", None)):
        if t is None:
            t = refresh(client_id, tokens["refresh_token"])["access_token"]
        assert_read_only(rest_write(t, a, "after.md"), f"{label} token, A write->read")
        assert rest_read(t, a).status_code == 200
        assert rest_write(t, b, f"{label}.md").status_code in (200, 201), f"{label} token, B"
        assert_rest_refused(t, c, f"{label} token, C read->none")
        assert listed_vaults(t) == {a, b}, f"{label} token list_vaults"


def test_another_users_vault_cannot_be_granted(user, other_user):
    a = user.vault("A")
    foreign = other_user.vault("Foreign")

    query = _redirect_query(consent(user.session(), register_client(), {a: "write", foreign: "read"}, "none"))
    assert "code" not in query, f"consent naming another user's vault issued a code: {query}"
    assert query.get("error") == ["access_denied"], query

    client_id, tokens = grant(user, {a: "write"}, "none")
    resp = patch_oauth(user, client_id, {a: "write", foreign: "read"}, "none")
    assert resp.status_code == 422, f"PATCH with foreign vault: {resp.status_code} {resp.text}"
    assert_rest_refused(tokens["access_token"], foreign, "grant token on foreign vault")

    key_resp = requests.post(
        f"{API_URL}/connections/pat",
        json={"name": "foreign", "vault_access": {foreign: "read"}, "default_access": "none"},
        headers=_bearer(user.session()),
        timeout=10,
    )
    assert key_resp.status_code == 422, f"key on foreign vault: {key_resp.status_code} {key_resp.text}"
