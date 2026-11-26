#!/usr/bin/env python3
"""REST driver for the rollback-compat workflow (.github/workflows/rollback-compat.yml).

The workflow boots OLD, then NEW, then OLD again on one database (a real
upgrade followed by a rollback). This script is the client side of each phase:

  seed-old    On OLD, before the upgrade: a self-host user, a vault and two
              marker-era explicit folders ("Legacy", "Legacy/Child"). NEW's
              boot stamps them (`explicit_seq = 0`); the workflow checks that.
  seed-new    On NEW: a root ("Root"), a nested ("Root/Nested") and a moved
              ("Mover" -> "Root/Moved") folder, all stamped by NEW's writers,
              and a root-only rename ("Legacy" -> "Renamed") that leaves the
              child's path hash stale, the case the boot stamp exists for.
              `--fault unstamped-row` also creates "Unstamped", which the
              workflow then unstamps in SQL (what a missing stamp leaves).
  verify-old  On OLD after the rollback: /folders/explicit and the vault
              tree list exactly the seeded set, then a rename and a delete
              through OLD and both listings again.

State (API key, vault id, expected folders) lives in a 0600 JSON file the
workflow keeps in $RUNNER_TEMP; nothing secret is printed.
"""

from __future__ import annotations

import argparse
import json
import os
import posixpath
import sys
import uuid

sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

from helpers.api import ApiClient  # noqa: E402
from helpers.auth_provider import LocalAuthProvider  # noqa: E402

LEGACY = ["Legacy", "Legacy/Child"]


def _load(state: str) -> dict:
    with open(state) as f:
        return json.load(f)


def _save(state: str, data: dict) -> None:
    fd = os.open(state, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    with os.fdopen(fd, "w") as f:
        json.dump(data, f)


def _client(api_url: str, data: dict) -> ApiClient:
    return ApiClient(api_url, data["api_key"]).with_vault(data["vault_id"])


def _expect(what: str, status: int, ok: tuple[int, ...]) -> None:
    if status not in ok:
        raise SystemExit(f"{what}: HTTP {status}, want one of {ok}")


def seed_old(api_url: str, state: str) -> None:
    email = f"rollback-compat-{uuid.uuid4().hex[:12]}@example.com"
    _, api_key = LocalAuthProvider(api_url).provision_user(email, uuid.uuid4().hex)
    vault, status = ApiClient(api_url, api_key).register_vault("rollback-compat", uuid.uuid4().hex)
    _expect("register vault", status, (200, 201))
    data = {"api_key": api_key, "vault_id": str(vault["id"])}
    client = _client(api_url, data)
    for folder in LEGACY:
        _expect(f"create {folder}", client.create_folder(folder), (200, 201))
    data["expected"] = sorted(LEGACY)
    _save(state, data)
    print(f"seed-old: created {LEGACY}")


def seed_new(api_url: str, state: str, fault: str) -> None:
    data = _load(state)
    client = _client(api_url, data)
    for folder in ("Root", "Root/Nested", "Mover"):
        _expect(f"create {folder}", client.create_folder(folder), (200, 201))
    _expect("move Mover -> Root/Moved", client.rename_folder("Mover", "Root/Moved"), (200,))
    _expect("rename Legacy -> Renamed", client.rename_folder("Legacy", "Renamed"), (200,))
    expected = {"Renamed", "Renamed/Child", "Root", "Root/Nested", "Root/Moved"}
    if fault == "unstamped-row":
        # Created LAST: the workflow unstamps the newest explicit row by id (uuidv7).
        _expect("create Unstamped", client.create_folder("Unstamped"), (200, 201))
        expected.add("Unstamped")
    data["expected"] = sorted(expected)
    _save(state, data)
    print(f"seed-new: expected explicit folders {data['expected']}")


def _note_folders(tree: dict) -> set[str]:
    """Every ancestor folder of the tree's notes and attachments."""
    out = set()
    for row in (tree.get("notes") or []) + (tree.get("attachments") or []):
        d = posixpath.dirname(row["path"])
        while d:
            out.add(d)
            d = posixpath.dirname(d)
    return out


def _check(client: ApiClient, expected: set[str], label: str) -> list[str]:
    errors = []
    explicit = client.get_explicit_folders()
    if explicit != expected:
        errors.append(
            f"{label}: /folders/explicit missing {sorted(expected - explicit)}, "
            f"extra {sorted(explicit - expected)}"
        )
    tree = client.get_vault_tree()
    folders = {f["name"] for f in tree.get("folders") or [] if f["name"]}
    want = expected | _note_folders(tree)
    if folders != want:
        errors.append(
            f"{label}: /vault/tree folders missing {sorted(want - folders)}, "
            f"extra {sorted(folders - want)}"
        )
    print(f"{label}: explicit={sorted(explicit)} tree={sorted(folders)}")
    return errors


def verify_old(api_url: str, state: str) -> None:
    data = _load(state)
    client = _client(api_url, data)
    expected = set(data["expected"])
    errors = _check(client, expected, "after rollback")

    status = client.rename_folder("Root/Nested", "Root/Nested2")
    if status != 200:
        errors.append(f"rename Root/Nested -> Root/Nested2 on OLD: HTTP {status}")
    status = client.delete_folder("Root/Moved")
    if status not in (200, 204):
        errors.append(f"delete Root/Moved on OLD: HTTP {status}")
    expected = (expected - {"Root/Nested", "Root/Moved"}) | {"Root/Nested2"}
    errors += _check(client, expected, "after OLD rename + delete")

    for e in errors:
        print(f"::error::{e}")
    if errors:
        raise SystemExit(1)
    print("verify-old: listings match")


def main() -> None:
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("phase", choices=["seed-old", "seed-new", "verify-old"])
    p.add_argument("--api-url", required=True, help="e.g. http://localhost:8110/api")
    p.add_argument("--state", required=True, help="0600 JSON state file")
    p.add_argument("--fault", choices=["none", "unstamped-row"], default="none")
    a = p.parse_args()
    if a.phase == "seed-old":
        seed_old(a.api_url, a.state)
    elif a.phase == "seed-new":
        seed_new(a.api_url, a.state, a.fault)
    else:
        verify_old(a.api_url, a.state)


if __name__ == "__main__":
    main()
