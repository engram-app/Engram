"""Programmatic device flow helpers for E2E tests.

These functions drive the device flow API without a browser,
used by both the Playwright test (to start the flow) and
potentially by other tests that need OAuth tokens.
"""

from __future__ import annotations

import logging
import time

import requests

logger = logging.getLogger(__name__)


def start_device_flow(base_url: str, client_id: str) -> dict:
    """Start a device flow. Returns {device_code, user_code, verification_url, ...}.

    POST /auth/device with client_id.
    Raises RuntimeError if the request fails.
    """
    resp = requests.post(
        f"{base_url}/auth/device",
        json={"client_id": client_id},
        timeout=10,
    )
    if resp.status_code != 200:
        raise RuntimeError(
            f"Failed to start device flow: HTTP {resp.status_code}\n{resp.text[:500]}"
        )
    data = resp.json()
    logger.info("Device flow started: user_code=%s", data.get("user_code"))
    return data


def _is_pending(resp) -> bool:
    """True when a 4xx body is the device flow's `authorization_pending`.

    RFC 8628 puts the discriminator in the body, not the status line. Anything
    unparseable is NOT pending — fail loudly rather than poll forever.
    """
    try:
        return resp.json().get("error") == "authorization_pending"
    except ValueError:
        return False


def exchange_device_code(base_url: str, device_code: str) -> dict | None:
    """Try to exchange a device code for tokens.

    POST /auth/device/token with device_code.
    Returns token dict on 200, None while pending, raises on other errors.

    Pending is 400 per RFC 8628 §3.5. 428 is the pre-2026-08 status this
    endpoint used; still accepted so the helper works against either side of
    a paired backend/plugin branch rollout.

    The discriminator is the BODY, not the status. `token/2` has no catch-all
    clause, so a malformed request (missing device_code) raises
    Phoenix.ActionClauseError and also lands as a 400 — treating bare 400 as
    "pending" would swallow it and surface 60s later as a misleading timeout
    instead of failing loudly right here.
    """
    resp = requests.post(
        f"{base_url}/auth/device/token",
        json={"device_code": device_code},
        timeout=10,
    )
    if resp.status_code == 200:
        return resp.json()
    if resp.status_code in (400, 428) and _is_pending(resp):
        return None
    raise RuntimeError(
        f"Device code exchange failed: HTTP {resp.status_code}\n{resp.text[:500]}"
    )


def poll_for_tokens(
    base_url: str, device_code: str, timeout: int = 60, interval: float = 2
) -> dict:
    """Poll /auth/device/token until authorized or timeout.

    Returns the token response dict. Raises TimeoutError if not authorized in time.
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        result = exchange_device_code(base_url, device_code)
        if result is not None:
            logger.info("Device code exchanged successfully")
            return result
        time.sleep(interval)
    raise TimeoutError(f"Device flow not authorized within {timeout}s")
