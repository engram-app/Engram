"""Sign a Clerk user into the SPA in a real browser without driving Clerk's UI.

A Backend API sign-in token rides in as `__clerk_ticket`; Clerk's <SignIn />
consumes it on load and redirects. The SPA passes `return_to` to Clerk as
`forceRedirectUrl` (auth/clerk-sign-in.tsx), which overrides Clerk's own
`redirect_url`, so both are set: `return_to` is the one that takes effect.
"""

from __future__ import annotations

import re
import time
from urllib.parse import quote

_TOKEN_BUDGET_S = 30.0
# Clerk dev-instance Frontend API. Same interception @clerk/testing's
# setupClerkTestingToken does, so bot protection never challenges the run.
_FAPI = re.compile(r"^https://[^/]+\.clerk\.accounts\.dev/v1/")


def clerk_sign_in_url(client, user_id: str, app_base: str, redirect_path: str) -> str:
    """Mint a 5-minute sign-in token for `user_id`; return the SPA sign-in URL.

    POST /sign_in_tokens lags POST /users like /sessions does (#455), so a
    404 resource_not_found is retried on a wall-clock budget; anything else raises.
    """
    deadline = time.monotonic() + _TOKEN_BUDGET_S
    while True:
        resp = client.session.post(
            f"{client.base_url}/sign_in_tokens",
            json={"user_id": user_id, "expires_in_seconds": 300},
            timeout=10,
        )
        if resp.ok:
            break
        lagging = resp.status_code == 404 and any(
            e.get("code") == "resource_not_found" for e in resp.json().get("errors", [])
        )
        if not lagging or time.monotonic() >= deadline:
            resp.raise_for_status()
        time.sleep(1)
    token = resp.json()["token"]
    return (
        f"{app_base}/sign-in?__clerk_ticket={token}"
        f"&redirect_url={quote(app_base + redirect_path, safe='')}"
        f"&return_to={quote(redirect_path, safe='')}"
    )


async def install_testing_token(context, client) -> None:
    """Append a Clerk testing token to every Frontend API call in `context`."""
    token = client.get_testing_token()

    async def _route(route):
        url = route.request.url
        sep = "&" if "?" in url else "?"
        await route.continue_(url=f"{url}{sep}__clerk_testing_token={token}")

    await context.route(_FAPI, _route)
