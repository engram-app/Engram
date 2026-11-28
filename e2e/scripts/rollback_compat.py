#!/usr/bin/env python3
"""REST driver for the rollback-compat workflow (.github/workflows/rollback-compat.yml).

The workflow boots OLD, then NEW, then OLD again on one database (a real
upgrade followed by a rollback). This script is the client side of each phase:

  seed-old    On OLD, before the upgrade: a self-host user, a vault and two
              marker-era explicit folders ("Legacy", "Legacy/Child"). NEW's
              boot stamps them (`explicit_seq = 0`); the workflow checks that.
  seed-new    On NEW, every writer that makes or keeps a row explicit: create,
              move, nested rename, a root-only rename that leaves a child's
              path hash stale ("Legacy" -> "Renamed"), a folder a note
              implied first, a batch create, a revive, a trash restore, a
              merge restore and a rename onto an occupied folder (a merge). Snapshots the tree's (id, parent_id) per folder.
              `--fault unstamped-row` also creates "Unstamped", which the
              workflow then unstamps in SQL (what a missing stamp leaves).
  verify-old  On OLD after the rollback: /folders/explicit and the vault
              tree list exactly the seeded set with NEW's ids and parents,
              then a rename and a delete through OLD and both again.

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


def seed_old(api_url: str, state: str, notes: bool = False) -> None:
    email = f"rollback-compat-{uuid.uuid4().hex[:12]}@example.com"
    _, api_key = LocalAuthProvider(api_url).provision_user(email, uuid.uuid4().hex)
    vault, status = ApiClient(api_url, api_key).register_vault("rollback-compat", uuid.uuid4().hex)
    _expect("register vault", status, (200, 201))
    data = {"api_key": api_key, "vault_id": str(vault["id"])}
    client = _client(api_url, data)
    for folder in LEGACY:
        _expect(f"create {folder}", client.create_folder(folder), (200, 201))
    if notes:
        # Notes at the root, in an explicit folder, and deep under one.
        seeded = ("root-note.md", "Legacy/note.md", "Legacy/Child/deep/note.md")
        for path in seeded:
            client.create_note(path, f"seeded on OLD: {path}")  # raises on any non-2xx
        listed = {n["path"] for n in client.get_vault_tree().get("notes") or []}
        if not set(seeded) <= listed:
            raise SystemExit(f"seed-old: OLD does not list its own notes {sorted(set(seeded) - listed)}")
    data["expected"] = sorted(LEGACY)
    _save(state, data)
    print(f"seed-old: created {LEGACY}")


def _mcp(client: ApiClient, data: dict, tool: str, args: dict) -> dict:
    return client.mcp_tool(tool, {"vault_id": data["vault_id"], **args})["structuredContent"]


def _delete_op(client: ApiClient, data: dict, folder: str) -> str:
    op = _mcp(client, data, "delete_folder", {"folder": folder}).get("delete_op_id")
    if not op:
        raise SystemExit(f"MCP delete_folder {folder}: no delete_op_id")
    return op


def seed_new(api_url: str, state: str, fault: str) -> None:
    """Every NEW writer that makes or keeps a row explicit, once each."""
    data = _load(state)
    client = _client(api_url, data)
    # create: a root, a nested folder, one to move.
    for folder in ("Root", "Root/Nested", "Mover"):
        _expect(f"create {folder}", client.create_folder(folder), (200, 201))
    # move, nested rename, root-only rename (leaves Legacy/Child's path hash stale).
    _expect("move Mover -> Root/Moved", client.rename_folder("Mover", "Root/Moved"), (200,))
    _expect("rename Root/Nested -> Root/Inner", client.rename_folder("Root/Nested", "Root/Inner"), (200,))
    _expect("rename Legacy -> Renamed", client.rename_folder("Legacy", "Renamed"), (200,))
    # A folder a note implied first, then made explicit (an existing implicit row).
    client.create_note("Implied/note.md", "implied by a note")
    _expect("create Implied", client.create_folder("Implied"), (200, 201))
    # Batch create (the plugin's push path): two leaves, their parent stays implicit.
    resp = client.session.post(
        f"{client.base_url}/folders/batch", json={"folders": ["Batch/One", "Batch/Two"]}, timeout=10
    )
    _expect("batch create Batch/One, Batch/Two", resp.status_code, (200, 201))
    # Revive: delete, then create at the same path.
    _expect("create Revived", client.create_folder("Revived"), (200, 201))
    _expect("delete Revived", client.delete_folder("Revived"), (200, 204))
    _expect("re-create Revived", client.create_folder("Revived"), (200, 201))
    # Trash restore.
    _expect("create Trashed", client.create_folder("Trashed"), (200, 201))
    _mcp(client, data, "restore_deleted", {"op_id": _delete_op(client, data, "Trashed")})
    # Merge restore: restore a deleted folder onto a live one at its path (the keeper).
    _expect("create Merged", client.create_folder("Merged"), (200, 201))
    merged_orig = _id(client, "Merged")
    op = _delete_op(client, data, "Merged")
    _expect("re-create Merged", client.create_folder("Merged"), (200, 201))
    merged_new = _id(client, "Merged")
    _mcp(client, data, "restore_deleted", {"op_id": op})
    merged = _id(client, "Merged")
    if merged_orig == merged_new or merged not in (merged_orig, merged_new):
        raise SystemExit(f"merge restore: Merged ids orig={merged_orig} new={merged_new} after={merged}")
    # Rename merge (Rows.retire/2): an explicit folder holding a note renamed
    # onto a path only a NESTED note occupies (a note directly in Dup makes
    # the rename gate answer 409): Rows.rename/4 merges the subtree, its note
    # moves under Dup, and the implicit Dup row takes the explicit flag.
    client.create_note("Dup/inner/x.md", "occupies Dup only below it")
    _expect("create Src", client.create_folder("Src"), (200, 201))
    client.create_note("Src/a.md", "moves into Dup with the merge")
    src = _id(client, "Src")
    _expect("rename Src -> Dup (merge)", client.rename_folder("Src", "Dup"), (200,))
    dup = _id(client, "Dup")
    if dup == src:
        raise SystemExit(f"rename merge: Dup kept Src's id {src}, so nothing merged")
    paths = {r["path"] for r in client.get_vault_tree().get("notes") or []}
    if "Dup/a.md" not in paths or "Src/a.md" in paths:
        raise SystemExit(f"rename merge: Src/a.md did not move under Dup ({sorted(p for p in paths if 'a.md' in p)})")
    # The workflow checks these rows in SQL: the survivor stamped, the other retired.
    data["merges"] = {
        "merge_restore": {"live": merged, "retired": merged_new if merged == merged_orig else merged_orig},
        "rename_merge": {"live": dup, "retired": src},
    }
    expected = {
        "Renamed", "Renamed/Child", "Root", "Root/Inner", "Root/Moved", "Implied",
        "Batch/One", "Batch/Two", "Revived", "Trashed", "Merged", "Dup",
    }
    if fault in ("unstamped-row", "vault-lock"):
        # Created LAST: the workflow unstamps the newest explicit row by id (uuidv7).
        _expect("create Unstamped", client.create_folder("Unstamped"), (200, 201))
        expected.add("Unstamped")
    data["expected"] = sorted(expected)
    tree = client.get_vault_tree()
    data["tree"] = _tree_rows(tree)
    # Every live note NEW serves, by id: verify-old's read-back must find
    # exactly these (a short or empty listing is a failure, not "0 of 0").
    data["notes"] = {str(n["id"]): n["path"] for n in tree.get("notes") or []}
    if not data["notes"]:
        raise SystemExit("seed-new: NEW's tree lists no notes, so the read-back would prove nothing")
    errors = _check(client, expected, "NEW after seeding", data["tree"])
    if errors:
        raise SystemExit("NEW's own listings do not match its seed: " + "; ".join(errors))
    _save(state, data)
    print(f"seed-new: expected explicit folders {data['expected']}")


def _id(client: ApiClient, name: str) -> str:
    ident = _tree_rows(client.get_vault_tree()).get(name, [None])[0]
    if not ident:
        raise SystemExit(f"{name}: no id in the vault tree")
    return ident


def _ancestors(path: str) -> set[str]:
    out = set()
    d = posixpath.dirname(path)
    while d:
        out.add(d)
        d = posixpath.dirname(d)
    return out


def _tree_rows(tree: dict) -> dict[str, list]:
    """Tree folders by name: [id, parent_id], what a client keys on."""
    return {f["name"]: [f.get("id"), f.get("parent_id")] for f in tree.get("folders") or [] if f["name"]}


def _check(client: ApiClient, expected: set[str], label: str, rows: dict | None = None) -> list[str]:
    """Explicit names equal `expected`; tree folders are those plus every
    file's folders; with `rows`, each tree folder keeps the id and parent
    id NEW served."""
    errors = []
    explicit = client.get_explicit_folders()
    if explicit != expected:
        errors.append(
            f"{label}: /folders/explicit missing {sorted(expected - explicit)}, "
            f"extra {sorted(explicit - expected)}"
        )
    tree = client.get_vault_tree()
    got = _tree_rows(tree)
    # The tree lists explicit folders and every folder holding a file (an
    # empty implicit parent, like Batch, is not listed).
    want = set(expected)
    for r in (tree.get("notes") or []) + (tree.get("attachments") or []):
        want |= _ancestors(r["path"])
    if set(got) != want:
        errors.append(
            f"{label}: /vault/tree folders missing {sorted(want - set(got))}, "
            f"extra {sorted(set(got) - want)}"
        )
    for name, ids in sorted((rows or {}).items()):
        if name in got and got[name] != ids:
            errors.append(f"{label}: {name} is {got[name]} (id, parent_id), NEW served {ids}")
    print(f"{label}: explicit={sorted(explicit)} tree={sorted(got)}")
    return errors


def _smoke_writes(client: ApiClient, data: dict) -> list[str]:
    """OLD's write and read paths on NEW's schema: folder create, note
    write and read, MCP list_folder and a (recent-mode) MCP search."""
    errors = []
    path, body = "PostRollback/n.md", "written by OLD after the rollback"
    if client.create_folder("PostRollback") not in (200, 201):
        errors.append("create PostRollback on OLD failed")
    try:
        client.create_note(path, body)
        note = client.get_note(path) or {}
        if body not in (note.get("content") or ""):
            errors.append(f"read back {path} on OLD: content {str(note.get('content'))[:80]!r}")
        listed = json.dumps(_mcp(client, data, "list_folder", {"folder": "PostRollback"}))
        if path not in listed and "n.md" not in listed:
            errors.append(f"MCP list_folder PostRollback on OLD does not list {path}: {listed[:200]}")
        found = json.dumps(_mcp(client, data, "search_notes", {"folder": "PostRollback", "limit": 5}))
        if path not in found:
            errors.append(f"MCP search_notes on OLD does not find {path}: {found[:200]}")
        moved = "PostRollback/m.md"
        status = client.rename_note(path, moved)
        got = client.get_note(moved) or {}
        if status != 200 or body not in (got.get("content") or ""):
            errors.append(f"rename {path} -> {moved} on OLD: HTTP {status}, not readable at the new path")
        # The workflow checks this row's name_key in SQL (OLD's write under NEW's trigger).
        data["post_rollback_id"] = str(got.get("id") or "")
    except Exception as e:  # any failure is a finding, reported with the rest (not swallowed)
        errors.append(f"OLD note/MCP smoke raised {type(e).__name__}: {str(e)[:200]}")
    print(f"OLD write smoke: {len(errors)} errors")
    return errors


def _read_every_note(client: ApiClient, want: dict[str, str], fault: str = "none") -> list[str]:
    """OLD's tree must list exactly the notes NEW served (`want`, id -> path),
    and each must read back by its path as the same id: a path lookup goes
    through path_hmac, which a later release may leave NULL."""
    errors = []
    notes = client.get_vault_tree().get("notes") or []
    if fault == "zero-notes":
        # Red proof of the floor: OLD's tree as if it listed no note.
        print(f"fault zero-notes: dropped {len(notes)} listed notes")
        notes = []
    listed = {str(n["id"]): n["path"] for n in notes}
    if not want or listed != want:
        errors.append(
            f"OLD's tree lists {len(listed)} notes, NEW served {len(want)}: "
            f"missing {sorted(set(want) - set(listed))}, extra {sorted(set(listed) - set(want))}, "
            f"moved {sorted(i for i in set(want) & set(listed) if want[i] != listed[i])}"
        )
    read = 0
    for ident, path in sorted(listed.items()):
        got = client.get_note(path)
        if got and str(got.get("id")) == ident:
            read += 1
        else:
            errors.append(f"note {ident} listed at {path} but OLD does not read it there (got {got and got.get('id')})")
    print(f"OLD read {read} of {len(want)} notes NEW served back by path ({len(listed)} listed)")
    return errors


def verify_old(api_url: str, state: str, writes: bool = False, read_notes: bool = False, fault: str = "none") -> None:
    data = _load(state)
    client = _client(api_url, data)
    expected = set(data["expected"])
    rows = data["tree"]
    errors = _check(client, expected, "after rollback", rows)

    status = client.rename_folder("Root/Inner", "Root/Inner2")
    if status != 200:
        errors.append(f"rename Root/Inner -> Root/Inner2 on OLD: HTTP {status}")
    status = client.delete_folder("Root/Moved")
    if status not in (200, 204):
        errors.append(f"delete Root/Moved on OLD: HTTP {status}")
    expected = (expected - {"Root/Inner", "Root/Moved"}) | {"Root/Inner2"}
    # The renamed folder keeps its id and parent; the rest are untouched.
    rows = {k: v for k, v in rows.items() if k not in ("Root/Inner", "Root/Moved")}
    rows["Root/Inner2"] = data["tree"].get("Root/Inner")
    errors += _check(client, expected, "after OLD rename + delete", rows)
    if read_notes:
        errors += _read_every_note(client, data.get("notes") or {}, fault)
    if writes:
        errors += _smoke_writes(client, data)
        errors += _check(client, expected | {"PostRollback"}, "after OLD writes", rows)

    _save(state, data)
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
    p.add_argument("--fault", choices=["none", "unstamped-row", "vault-lock", "hash-read", "path-hash-null", "verdict-count", "zero-notes"], default="none")
    p.add_argument("--with-notes", action="store_true", help="seed-old: notes too, nested")
    p.add_argument("--writes", action="store_true", help="verify-old: also folder create, note write/read/rename, MCP list_folder and search")
    p.add_argument("--read-notes", action="store_true", help="verify-old: read every listed note back by path")
    a = p.parse_args()
    if a.phase == "seed-old":
        seed_old(a.api_url, a.state, a.with_notes)
    elif a.phase == "seed-new":
        seed_new(a.api_url, a.state, a.fault)
    else:
        verify_old(a.api_url, a.state, a.writes, a.read_notes, a.fault)


if __name__ == "__main__":
    main()
