"""Safety guards for the load simulator: target allowlist and a spend cap."""

from __future__ import annotations

import threading
from urllib.parse import urlsplit

# Hosts a load run may target without the override flag: staging, the FastRaid
# LAN host (staging + self-host containers), and a local stack.
STAGING_HOSTS = frozenset(
    {"staging.engram.page", "10.0.20.214", "localhost", "127.0.0.1"}
)


class TargetRefused(SystemExit):
    """Raised (and exits non-zero) when a run would aim somewhere it must not."""


def check_target(api: str, allow_any_host: bool) -> None:
    parts = urlsplit(api)
    if parts.scheme not in ("http", "https") or not parts.hostname:
        raise TargetRefused(f"--api must be an http(s) URL, got {api!r}")
    if not allow_any_host and parts.hostname not in STAGING_HOSTS:
        raise TargetRefused(
            f"refusing to load {parts.hostname}: not a staging host ({', '.join(sorted(STAGING_HOSTS))}). "
            "Pass --i-know-this-is-not-staging only if you mean it."
        )


def check_clerk_key(key: str) -> None:
    if not key.strip():
        raise TargetRefused("STAGING_CLERK_SECRET_KEY is empty")
    if key.startswith("sk_live_"):
        raise TargetRefused(
            "refusing a live Clerk key (sk_live_): the sim only runs against a test instance"
        )


class SpendGuard:
    """Running cap on estimated embed tokens. `take` reserves before the write."""

    def __init__(self, cap: int):
        self.cap = cap
        self.spent = 0
        self.refused = 0
        self._lock = threading.Lock()

    def take(self, tokens: int) -> bool:
        with self._lock:
            if self.spent + tokens > self.cap:
                self.refused += 1
                return False
            self.spent += tokens
            return True
