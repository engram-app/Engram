"""Test 70: Stale local file (mtime >1 h older than remote, no sync hash)
is accepted as remote-authoritative on pull — no conflict modal is raised.

User path covered:
  On first sync for a file the plugin has no sync hash for it.  It uses an
  mtime heuristic to decide whether the local copy was user-edited (and should
  trigger a conflict) or is just an old stale copy that predates the remote
  version.  If remote_mtime - local_mtime > STALE_THRESHOLD_S (3600 s) the
  file is treated as stale and the remote version silently overwrites it without
  opening a conflict modal (src/sync.ts lines 1332–1338).

Implementation notes vs plan draft:
  - Plan draft used JavaScript `delete p.syncEngine.syncState[path]` to clear
    the sync hash.  However syncState is a `Map<string, FileSyncState>`
    (src/sync.ts line 150); bracket-delete does nothing on a Map.  The correct
    call is `p.syncEngine.syncState.delete(path)`.  Obsidian normalizes vault
    paths via normalizePath() before storing them, so we must pass the same
    normalized form (forward slashes, no leading slash — identical to the
    original path string for normal vault-relative paths like "E2E/Stale70/Old.md").
  - The test writes to vault A with a backdated mtime and writes the authoritative
    content to the server via api_sync.create_note, then triggers a pull on A.
    This is simpler and faster than the plan's vault_b round-trip (which depends
    on B's debounce/push timing) while exercising the exact same code path.
  - savePluginData() is not called after the syncState.delete() because a call to
    saveSettings() would trigger setupNoteStream() + registerVault() causing
    side-effects that complicate the test.  The in-memory deletion is enough to
    put the engine in the "no sync hash" state that triggers the staleness branch.
  - Cleanup: after assertions, delete the file from vault A (and server) so the
    stale mtime artifact does not affect downstream tests.

Seed/restore notes:
  The test creates a server note, seeds vault A with an old mtime, deletes the
  syncState entry in-memory, runs a pull, asserts the content was overwritten,
  then deletes the file from both vault A (filesystem) and the server.
"""

from __future__ import annotations

import asyncio
import os
import time

import pytest

from helpers.vault import write_note, read_note, delete_note


PLUGIN_ID = "engram-vault-sync"
_P = f"app.plugins.plugins['{PLUGIN_ID}']"
_ENGINE = f"{_P}.syncEngine"

# Same threshold as src/sync.ts STALE_THRESHOLD_S
_STALE_THRESHOLD_S = 3600


@pytest.mark.asyncio
async def test_stale_local_accepts_remote(vault_a, cdp_a, api_sync):
    """Stale local file (>1 h older than server copy, no sync hash) is overwritten
    by the remote version on pull without raising a conflict."""

    path = "E2E/Stale70/Old.md"
    local_content = "# local stale copy"
    remote_content = "# remote authoritative version"

    # ------------------------------------------------------------------ #
    # Step 1: Push authoritative content to the server via API so A will  #
    # receive it on pull.  Use a current mtime so the server version is   #
    # clearly "newer" than our backdated local copy.                      #
    # ------------------------------------------------------------------ #
    api_sync.create_note(path, remote_content, mtime=time.time())

    try:
        # ------------------------------------------------------------------ #
        # Step 2: Write a stale local copy to vault A and backdate its mtime #
        # to 2 hours ago — well past STALE_THRESHOLD_S (3600 s).            #
        # ------------------------------------------------------------------ #
        write_note(vault_a, path, local_content)
        two_hours_ago = time.time() - 2 * _STALE_THRESHOLD_S
        os.utime(str(vault_a / path), (two_hours_ago, two_hours_ago))

        # ------------------------------------------------------------------ #
        # Step 3: Clear the in-memory sync hash for this path so the engine  #
        # enters the "no sync hash → staleness heuristic" branch.            #
        # syncState is a Map; use .delete() not bracket-delete.              #
        # ------------------------------------------------------------------ #
        await cdp_a.evaluate(
            f"{_ENGINE}.syncState.delete({path!r})"
        )

        # Confirm deletion took effect.
        has_hash = await cdp_a.evaluate(
            f"{_ENGINE}.syncState.has({path!r})"
        )
        assert not has_hash, (
            "syncState still has an entry for the test path after .delete() — "
            "the staleness branch won't fire.  Check path normalization."
        )

        # ------------------------------------------------------------------ #
        # Step 3b: Make Obsidian's *cached* TFile.stat.mtime reflect the       #
        # backdated value deterministically.  The staleness branch reads       #
        # existing.stat.mtime (Obsidian's in-memory cache — src/sync.ts ~1376),#
        # NOT the on-disk mtime.  Obsidian's file-watcher does not reliably    #
        # observe a metadata-only os.utime() (no content change) within a      #
        # bounded window, so *passively* waiting for the cache to refresh is a #
        # seeding race (issue #343).  Instead force the cache to match the     #
        # authoritative on-disk stat: read app.vault.adapter.stat() (a direct  #
        # disk read → the backdated value) and write it onto the cached        #
        # TFile.stat.  We poll only for the TFile to be *indexed* — new-file   #
        # creation IS reliably observed by the watcher; the metadata reconcile #
        # itself is deterministic.                                             #
        # ------------------------------------------------------------------ #
        seed_age_s = None
        for _ in range(40):  # up to ~10 s — waiting only for the file to be indexed
            seed_age_s = await cdp_a.evaluate(
                "(async () => {"
                f"  const f = app.vault.getFileByPath({path!r});"
                "  if (!f) return null;"  # not indexed by Obsidian yet → retry
                f"  const s = await app.vault.adapter.stat({path!r});"
                "  if (!s) return null;"
                "  f.stat.mtime = s.mtime;"
                "  f.stat.ctime = s.ctime;"
                "  f.stat.size = s.size;"
                "  return (Date.now() - f.stat.mtime) / 1000;"
                "})()",
                await_promise=True,
            )
            if seed_age_s is not None:
                break
            await asyncio.sleep(0.25)

        assert seed_age_s is not None and seed_age_s > _STALE_THRESHOLD_S, (
            "Could not seed a stale cached stat.mtime for the test file: the TFile was "
            f"never indexed by Obsidian, or its reconciled on-disk mtime ({seed_age_s!r}s "
            "old) is not past STALE_THRESHOLD_S.  This is the seeding precondition, not "
            "the behavior under test (issue #343)."
        )

        # ------------------------------------------------------------------ #
        # Step 4: Trigger a pull on A.  The engine sees:                     #
        #   - local file exists (just written above)                          #
        #   - no sync hash → staleness heuristic branch                      #
        #   - remote_mtime - local_mtime >> STALE_THRESHOLD_S                #
        #   → stale = true → localModified = false → overwrite without modal #
        # ------------------------------------------------------------------ #
        await cdp_a.trigger_pull()

        # Give Obsidian a moment to write the pulled content to disk.
        await asyncio.sleep(1)

        # ------------------------------------------------------------------ #
        # Step 5: Assert the local file now has the remote content.          #
        # ------------------------------------------------------------------ #
        actual = read_note(vault_a, path)
        assert remote_content in actual, (
            f"Vault A still has stale content after pull.  Got: {actual!r}. "
            "Expected remote content to overwrite the stale local copy without "
            "a conflict (staleness branch in src/sync.ts applyChange, line ~1337)."
        )

        # Confirm no conflict modal was opened (it would block the test if shown).
        conflict_modal_open = await cdp_a.evaluate(
            "Boolean(document.querySelector('.engram-conflict-modal'))"
        )
        assert not conflict_modal_open, (
            "Conflict modal is open — the staleness branch did not suppress it.  "
            "Check STALE_THRESHOLD_S comparison in src/sync.ts applyChange."
        )

    finally:
        # Clean up: remove file from vault A and server.
        delete_note(vault_a, path)
        try:
            api_sync.delete_note(path)
        except Exception:
            pass
        # Final sync to leave the engine in a clean state.
        try:
            await cdp_a.trigger_full_sync()
        except Exception:
            pass
