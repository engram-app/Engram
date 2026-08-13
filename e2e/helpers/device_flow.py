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


def exchange_device_code(base_url: str, device_code: str) -> dict | None:
    """Try to exchange a device code for tokens.

    POST /auth/device/token with device_code.
    Returns token dict on 200, None while pending, raises on other errors.

    Pending is 400 per RFC 8628 §3.5. 428 is the pre-2026-08 status this
    endpoint used; still accepted so the helper works against either side of
    a paired backend/plugin branch rollout.
    """
    resp = requests.post(
        f"{base_url}/auth/device/token",
        json={"device_code": device_code},
        timeout=10,
    )
    if resp.status_code == 200:
        return resp.json()
    if resp.status_code in (400, 428):
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
