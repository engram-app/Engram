#!/usr/bin/env python3
"""Bulk-delete orphaned CI Qdrant collections from the shared SlowRaid Qdrant.

CI creates a per-run collection (``ci_test_<run_id>_obsidian``, ``ci_crdt_<run_id>``)
and deletes it on teardown — but that teardown ``DELETE`` is best-effort
(``curl ... || true``), so a cancelled job or an unreachable Qdrant leaks the
collection. Left unchecked they accumulate (297 orphans on 2026-07-19) until
Qdrant ENOMEM-panics loading every shard on boot → crash loop → CI-wide outage.

This reaper deletes every ``ci_test_*`` / ``ci_crdt_*`` collection whose GitHub
run is no longer active (not queued/in_progress). Real collections
(``obsidian_notes``, …) never match the ``ci_`` prefix, so they are never
touched.

Usage:
    QDRANT_URL=http://10.0.20.201:6333 GITHUB_TOKEN=... \
      GITHUB_REPOSITORY=engram-app/engram \
      python e2e/scripts/cleanup_qdrant_collections.py [--dry-run]
"""

from __future__ import annotations

import argparse
import logging
import os
import re
import sys

import requests

logging.basicConfig(level=logging.INFO, format="%(levelname)s: %(message)s")
logger = logging.getLogger(__name__)

# CI collection names embed the GitHub run id: `ci_test_<id>_obsidian`,
# `ci_crdt_<id>`, or the bare `ci_test_notes` compose default (no id).
_CI_COLLECTION_RE = re.compile(r"^ci_(?:test|crdt)_")
_RUN_ID_RE = re.compile(r"^ci_(?:test|crdt)_(\d+)")


def is_ci_collection(name: str) -> bool:
    """True iff `name` is a CI-created collection (never a real vault)."""
    return bool(_CI_COLLECTION_RE.match(name))


def run_id_of(name: str) -> str | None:
    """The GitHub run id embedded in a CI collection name, or None."""
    m = _RUN_ID_RE.match(name)
    return m.group(1) if m else None


def orphaned_ci_collections(names: list[str], active_run_ids: set[str]) -> list[str]:
    """CI collections whose owning run is not active.

    A CI name with no parseable run id (e.g. the `ci_test_notes` compose
    default) is always orphaned — no active run owns it. Non-CI collections are
    never returned.
    """
    orphans = []
    for name in names:
        if not is_ci_collection(name):
            continue
        rid = run_id_of(name)
        if rid is None or rid not in active_run_ids:
            orphans.append(name)
    return orphans


def list_collections(session: requests.Session, qdrant_url: str) -> list[str]:
    resp = session.get(f"{qdrant_url}/collections", timeout=15)
    resp.raise_for_status()
    return [c["name"] for c in resp.json()["result"]["collections"]]


def fetch_active_run_ids(session: requests.Session, repo: str, token: str) -> set[str]:
    """Currently queued + in-progress GitHub Actions run ids for `repo`.

    Raises on any API error — the caller MUST abort rather than reap blind (an
    empty set from a failed call would delete a live run's collection).
    """
    ids: set[str] = set()
    headers = {"Authorization": f"Bearer {token}", "Accept": "application/vnd.github+json"}
    for status in ("in_progress", "queued"):
        url = f"https://api.github.com/repos/{repo}/actions/runs?status={status}&per_page=100"
        while url:
            resp = session.get(url, headers=headers, timeout=15)
            resp.raise_for_status()
            for run in resp.json().get("workflow_runs", []):
                ids.add(str(run["id"]))
            url = resp.links.get("next", {}).get("url")
    return ids


def delete_collection(session: requests.Session, qdrant_url: str, name: str) -> bool:
    resp = session.delete(f"{qdrant_url}/collections/{name}", timeout=30)
    return resp.ok


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dry-run", action="store_true", help="list orphans without deleting")
    args = ap.parse_args()

    qdrant_url = os.environ.get("QDRANT_URL", "http://10.0.20.201:6333").rstrip("/")
    repo = os.environ.get("GITHUB_REPOSITORY", "engram-app/engram")
    token = os.environ.get("GITHUB_TOKEN", "")

    if not token:
        logger.error("GITHUB_TOKEN is required — the active-run guard prevents deleting a live run's collection")
        return 1

    session = requests.Session()

    # Order matters: list collections FIRST, then fetch active runs. A collection
    # present now belongs to a run that started before this listing; if that run
    # is still active by the (later) active-run fetch it stays in the set and is
    # kept — so a live run's collection can never be reaped.
    try:
        collections = list_collections(session, qdrant_url)
    except Exception as e:
        logger.error("Qdrant unreachable at %s: %s", qdrant_url, e)
        return 1

    try:
        active = fetch_active_run_ids(session, repo, token)
    except Exception as e:
        logger.error("Could not fetch active GitHub runs (%s) — aborting rather than reaping blind", e)
        return 1

    orphans = orphaned_ci_collections(collections, active)
    ci_total = sum(1 for c in collections if is_ci_collection(c))
    logger.info(
        "Qdrant: %d collections (%d CI), %d active runs, %d orphans to reap",
        len(collections), ci_total, len(active), len(orphans),
    )

    deleted = 0
    for name in orphans:
        if args.dry_run:
            logger.info("[dry-run] would delete %s", name)
            continue
        if delete_collection(session, qdrant_url, name):
            deleted += 1
        else:
            logger.warning("failed to delete collection %s", name)

    logger.info(
        "Reaped %d/%d orphan CI collections%s",
        len(orphans) if args.dry_run else deleted,
        len(orphans),
        " (dry-run)" if args.dry_run else "",
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
