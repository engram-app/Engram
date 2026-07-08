"""Test 86: Advanced sync choices — outcome semantics for all four buttons.

test_55 covers the SyncPreviewModal UI (typed-"delete" gate, choice dispatch)
with a swallowing spy — the sync itself never runs. This module covers what
the buttons actually DO: for each of the four advanced choices, seed a
divergent state and assert the final note set on BOTH sides.

The four choices form a 2x2 (direction x delete-extras):

  push-all-keep-remote    — upload local; remote extras survive
  push-all-delete-remote  — wipe remote, then upload local (remote := local)
  pull-all-keep-local     — download remote; local extras survive
  pull-all-delete-local   — wipe local, then download remote (local := remote)

Incident coverage (2026-07-08 vault wipe): push-all-delete-remote's
wipeRemote() REST-deletes every remote note while the WS channel is live.
The server broadcasts each delete with mode=fanout and no origin attribution,
so the deleting device receives its own deletes back; the WS handler exempts
deletes from echo suppression (sync.ts) and trashed the entire local vault
before the upload phase enumerated files — pushed=0, both sides empty.
test_push_all_delete_remote_preserves_local pins the invariant: a replace-
remote sync must NEVER delete local files (immediately or via late echo).

The mirror invariant is pinned for pull-all-delete-local: the local wipe must
not echo-push deletions to the server (suppressVaultDeleteEvents path).

Seed per test (unique folder, rerun-safe):
  Synced.md     — on both sides (created locally, pushed before gate reset)
  LocalOnly.md  — vault only (created while the sync gate is blocked)
  RemoteOnly.md — server only (REST create while the sync gate is blocked)

Each test drives plugin.runSyncFromChoice(<choice>) — the exact dispatch the
modal's confirm button runs (markSyncGateAccepted + engine call) — rather
than the modal DOM, which test_55 already covers.

Settle re-asserts: WS echoes of the wipe arrive asynchronously; a state that
looks correct the instant the sync promise resolves can still be destroyed a
few seconds later (that is precisely how the incident unfolded). Destructive
tests therefore re-assert after SETTLE_S seconds.
"""

from __future__ import annotations

import asyncio
import json
import uuid

import pytest

from helpers.vault import read_note, wait_for_content, wait_for_file, wait_for_file_gone


SETTLE_S = 8


def _content(tag: str, unique: str) -> str:
    return f"# {tag}\n\nadvanced-sync seed {tag} {unique}\n"


async def _vault_create(cdp, path: str, content: str) -> None:
    """Create a file via app.vault so Obsidian's index sees it synchronously."""
    await cdp.evaluate(
        f"""
        (async () => {{
            const path = {json.dumps(path)};
            const content = {json.dumps(content)};
            const slash = path.lastIndexOf('/');
            if (slash > 0) {{
                const dir = path.slice(0, slash);
                if (!app.vault.getAbstractFileByPath(dir)) {{
                    try {{ await app.vault.createFolder(dir); }} catch (_) {{}}
                }}
            }}
            const existing = app.vault.getFileByPath(path);
            if (existing) {{ await app.vault.modify(existing, content); }}
            else {{ await app.vault.create(path, content); }}
        }})()
        """,
        await_promise=True,
    )


async def _run_choice(cdp, choice: str) -> None:
    """Dispatch exactly what the modal confirm runs for this choice."""
    from helpers.cdp import PLUGIN_PATH

    await cdp.evaluate(
        f"{PLUGIN_PATH}.runSyncFromChoice({json.dumps(choice)})",
        await_promise=True,
    )


class _Seed:
    def __init__(self, folder: str, unique: str):
        self.unique = unique
        self.synced = f"{folder}/Synced.md"
        self.local_only = f"{folder}/LocalOnly.md"
        self.remote_only = f"{folder}/RemoteOnly.md"
        self.synced_content = _content("Synced", unique)
        self.local_content = _content("LocalOnly", unique)
        self.remote_content = _content("RemoteOnly", unique)


async def _seed(cdp, api_sync) -> _Seed:
    """Build the divergent 3-file state. Leaves the sync gate BLOCKED."""
    unique = uuid.uuid4().hex[:12]
    s = _Seed(f"E2E/Adv86-{unique}", unique)

    # 1. Synced.md lands on both sides through a normal live push.
    await _vault_create(cdp, s.synced, s.synced_content)
    api_sync.wait_for_note(s.synced, timeout=30)

    # 2. Block the gate FIRST so neither of the divergent seeds crosses over
    #    (a live WS event would otherwise pull RemoteOnly.md into the vault).
    await cdp.reset_sync_gate()
    await _vault_create(cdp, s.local_only, s.local_content)
    api_sync.create_note(s.remote_only, s.remote_content)
    return s


async def _cleanup(cdp, vault, api_sync, s: _Seed) -> None:
    """Best-effort teardown: unblock sync, remove seeds on both sides."""
    try:
        await cdp.accept_sync_gate()
    except Exception:
        pass
    for path in (s.synced, s.local_only, s.remote_only):
        try:
            api_sync.delete_note(path)
        except Exception:
            pass
        try:
            await cdp.evaluate(
                f"""
                (async () => {{
                    const f = app.vault.getFileByPath({json.dumps(path)});
                    if (f) {{ try {{ await app.vault.delete(f); }} catch (_) {{}} }}
                }})()
                """,
                await_promise=True,
            )
        except Exception:
            pass
        fs_path = vault / path
        if fs_path.exists():
            fs_path.unlink()


# ---------------------------------------------------------------------------
# push-all-keep-remote — upload local, remote extras survive
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_push_all_keep_remote(vault_a, cdp_a, api_sync):
    s = await _seed(cdp_a, api_sync)
    try:
        await _run_choice(cdp_a, "push-all-keep-remote")

        # Local files reached the server.
        api_sync.wait_for_note(s.local_only, timeout=30)
        assert api_sync.get_note(s.synced) is not None

        # Remote extra survived a keep-remote push.
        remote = api_sync.get_note(s.remote_only)
        assert remote is not None, "keep-remote push deleted a remote-only note"

        # Nothing local was harmed.
        assert read_note(vault_a, s.local_only) == s.local_content
        assert read_note(vault_a, s.synced) == s.synced_content
    finally:
        await _cleanup(cdp_a, vault_a, api_sync, s)


# ---------------------------------------------------------------------------
# push-all-delete-remote — remote := local; LOCAL MUST SURVIVE (incident)
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_push_all_delete_remote_preserves_local(vault_a, cdp_a, api_sync):
    s = await _seed(cdp_a, api_sync)
    try:
        await _run_choice(cdp_a, "push-all-delete-remote")

        # Remote extra is gone; local files were uploaded.
        api_sync.wait_for_note_gone(s.remote_only, timeout=30)
        api_sync.wait_for_note(s.local_only, timeout=30)
        api_sync.wait_for_note(s.synced, timeout=30)

        # THE incident invariant: replacing remote must not touch local files.
        assert read_note(vault_a, s.local_only) == s.local_content, (
            "replace-remote sync deleted/altered LocalOnly.md"
        )
        assert read_note(vault_a, s.synced) == s.synced_content, (
            "replace-remote sync deleted/altered Synced.md"
        )

        # The wipe's delete broadcasts fan out asynchronously — the vault can
        # be destroyed AFTER the sync promise resolves. Hold the line.
        await asyncio.sleep(SETTLE_S)
        assert (vault_a / s.local_only).exists() and (vault_a / s.synced).exists(), (
            "late WS echo of wipeRemote deleted local files after the sync "
            "completed (2026-07-08 incident signature)"
        )
        assert read_note(vault_a, s.synced) == s.synced_content

        # And the server still holds the pushed notes (no post-push wipe).
        assert api_sync.get_note(s.synced) is not None
        assert api_sync.get_note(s.local_only) is not None
    finally:
        await _cleanup(cdp_a, vault_a, api_sync, s)


# ---------------------------------------------------------------------------
# pull-all-keep-local — download remote, local extras survive
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_pull_all_keep_local(vault_a, cdp_a, api_sync):
    s = await _seed(cdp_a, api_sync)
    try:
        await _run_choice(cdp_a, "pull-all-keep-local")

        # Remote-only note arrived locally.
        wait_for_content(vault_a, s.remote_only, f"RemoteOnly {s.unique}", timeout=30)

        # Local extra survived a keep-local pull.
        assert read_note(vault_a, s.local_only) == s.local_content, (
            "keep-local pull deleted a local-only file"
        )

        # Remote unchanged: pull never pushes, never deletes.
        assert api_sync.get_note(s.remote_only) is not None
        assert api_sync.get_note(s.synced) is not None
    finally:
        await _cleanup(cdp_a, vault_a, api_sync, s)


# ---------------------------------------------------------------------------
# pull-all-delete-local — local := remote; REMOTE MUST SURVIVE (mirror)
# ---------------------------------------------------------------------------

@pytest.mark.asyncio
async def test_pull_all_delete_local_preserves_remote(vault_a, cdp_a, api_sync):
    s = await _seed(cdp_a, api_sync)
    try:
        await _run_choice(cdp_a, "pull-all-delete-local")

        # Local matches remote: extra wiped, remote notes present.
        wait_for_file_gone(vault_a, s.local_only, timeout=30)
        wait_for_content(vault_a, s.remote_only, f"RemoteOnly {s.unique}", timeout=30)
        wait_for_file(vault_a, s.synced, timeout=30)

        # Mirror invariant of the incident: the local wipe must not echo-push
        # deletions up to the server (suppressed vault delete events).
        await asyncio.sleep(SETTLE_S)
        assert api_sync.get_note(s.remote_only) is not None, (
            "local wipe echoed a delete to the server (RemoteOnly.md gone)"
        )
        assert api_sync.get_note(s.synced) is not None, (
            "local wipe echoed a delete to the server (Synced.md gone)"
        )
    finally:
        await _cleanup(cdp_a, vault_a, api_sync, s)
