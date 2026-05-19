"""Shared conflict test setup — used by test_06, test_13, test_14, test_21, test_22,
test_54.

Extracts two patterns:

1. ``setup_conflict`` — the original 5-step pattern used by test_06/13/14/21/22:
   A creates base note, B syncs to get it, A edits, B pauses and edits locally.
   Requires api_sync fixture.

2. ``setup_conflict_for_a`` / ``restore_after_conflict`` — the simpler 2-party
   pattern for test_54 (ConflictModal UI):
   B writes remote content and syncs to server, then A writes local content and
   triggers pull so that Vault A detects divergence and opens ConflictModal
   (requires ``conflictResolution == 'modal'`` already set on A before call).
   Does NOT require api_sync.
"""

from __future__ import annotations

import asyncio
import time

from helpers.vault import write_note


async def setup_conflict(
    path: str,
    vault_a,
    vault_b,
    cdp_b,
    api_sync,
    *,
    a_edit: str = "Edited by A",
    b_edit: str = "Edited by B",
    base_content: str = "Base content",
):
    """Create a conflict: A and B both edit the same note.

    After this function returns:
    - Server has A's version
    - B has B's version locally (outgoing sync paused)
    - B's syncedHash records the original base, so pull will detect conflict

    Raises AssertionError if pause_outgoing_sync failed to prevent B's push.
    """
    # 1. A creates the base note
    write_note(vault_a, path, f"# Conflict Test\n{base_content}")
    api_sync.wait_for_note(path, timeout=10)

    # 2. B pulls to establish synced state (records syncedHash)
    await cdp_b.trigger_full_sync()
    assert (vault_b / path).exists(), "B should have the base note after pull"

    # 3. A edits → push to server
    write_note(vault_a, path, f"# Conflict Test\n{a_edit}")
    api_sync.wait_for_note_content(path, a_edit, timeout=10)

    # 4. Pause B's outgoing sync so B's edit stays local-only
    await cdp_b.pause_outgoing_sync()

    # 5. B edits locally
    write_note(vault_b, path, f"# Conflict Test\n{b_edit}")

    # 6. Verify pause is working — B's edit must NOT overwrite A's on server.
    #    Plugin debounce is 300ms; 1s = 3x margin for push to have fired if unpaused.
    time.sleep(1)
    server_note = api_sync.get_note(path)
    assert server_note is not None, "Server note disappeared during conflict setup"
    assert b_edit not in server_note.get("content", ""), (
        f"pause_outgoing_sync FAILED: B's edit '{b_edit}' reached the server. "
        f"All conflict tests using this helper are invalid."
    )


# ---------------------------------------------------------------------------
# Two-party conflict helpers for test_54 (ConflictModal UI)
# ---------------------------------------------------------------------------


async def setup_conflict_for_a(
    vault_a,
    vault_b,
    cdp_a,
    cdp_b,
    path: str,
    *,
    local: str,
    remote: str,
    base: str | None = None,
) -> None:
    """Seed a 3-way conflict that opens ConflictModal on Vault A.

    The plugin only treats a divergent pull as a *real* conflict when both:

      - it has a recorded ``syncedHash`` for the file (so the local edit is
        provably user-modified, not first-sync staleness), AND
      - ``localContent != remoteContent``.

    Without a recorded sync state the engine falls into its first-sync staleness
    heuristic (``STALE_THRESHOLD_S = 3600`` s; see src/sync.ts ~1330) and may
    silently accept the remote, never opening ConflictModal.

    So we establish a synced *base* first:

    1. A writes ``base`` content and triggers a full sync — server now has the
       base AND ``syncState`` on A records its hash.
    2. B also fully syncs so B has the same base recorded locally.
    3. Pause A's outgoing sync so A's divergent edit stays off-server.
    4. A writes ``local`` (diverges from base).
    5. B writes ``remote`` (diverges from base) and full-syncs — server now
       carries B's divergent version.
    6. Resume A's outgoing sync, then trigger a pull — A sees server content
       that differs from its local content AND its recorded base hash; with
       ``conflictResolution == 'modal'`` set, ConflictModal opens.

    If ``base`` is None, a deterministic placeholder is derived from ``path``.

    The caller MUST set ``conflictResolution = 'modal'`` on A before calling
    (the ``_set_modal_mode`` autouse fixture in test_54 does this).

    Waits up to 10 s for the modal DOM node to appear; raises TimeoutError if
    it never mounts.
    """
    if base is None:
        base = f"# base\nseed for {path}\n"

    # 0. Defensive: dismiss any leftover conflict modal from a prior aborted
    #    run.  pytest-rerunfailures retries the same test in the same browser
    #    process, so a previous attempt's open modal would block the new pull
    #    (resolveConflict is single-flight per file but a stale modal hides
    #    test failures behind a 180 s timeout).
    await cdp_a.evaluate(
        "(() => { "
        "const m = document.querySelector("
        "'.engram-conflict-modal .engram-conflict-actions'); "
        "if (!m) return; "
        "const skip = Array.from(m.querySelectorAll('button'))"
        ".find(b => b.textContent.trim() === 'Skip'); "
        "skip?.click(); "
        "})()"
    )

    # 1. A writes the base content and syncs — establishes syncedHash on A
    #    and base content on the server.
    write_note(vault_a, path, base)
    await cdp_a.trigger_full_sync()

    # 2. B pulls so it also records the same base in its syncState. Not strictly
    #    required for ConflictModal on A, but keeps both sides consistent for
    #    test_54's eventual restore.
    await cdp_b.trigger_full_sync()

    # 3. Pause A's outgoing sync so the local divergent write stays off-server.
    await cdp_a.pause_outgoing_sync()

    # 4. A writes local divergence (now: localHash != lastSyncedHash → modified).
    write_note(vault_a, path, local)

    # 5. B writes remote divergence and syncs so the server carries B's version.
    write_note(vault_b, path, remote)
    await cdp_b.trigger_full_sync()

    # 6. Resume A's outgoing sync, then pull — divergence is detected and
    #    ConflictModal opens.
    #
    # CRITICAL: do NOT await pull()'s promise here.  In 'modal' mode pull()
    # invokes resolveConflict() which awaits onConflict() — i.e. user
    # interaction with the modal we're trying to surface.  Awaiting the pull
    # would deadlock the seed: the seed waits for pull to resolve, pull waits
    # for the modal click, no test code has run yet to click.
    #
    # Fire-and-forget: dispatch pull() and rely on the modal-mount poll below
    # to know when the seed has reached the user-interaction point.
    await cdp_a.resume_outgoing_sync()
    # No await_promise — dispatch pull() and return immediately so the seed
    # can poll for the modal that pull() is about to surface.
    await cdp_a.evaluate(
        "void app.plugins.plugins['engram-vault-sync']"
        ".syncEngine.pull(); 'dispatched'"
    )

    # Wait for ConflictModal to mount (pull dispatches resolveConflict which
    # opens the modal asynchronously).
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        present = await cdp_a.evaluate(
            "Boolean(document.querySelector('.engram-conflict-modal'))"
        )
        if present:
            return
        await asyncio.sleep(0.2)
    raise TimeoutError(
        f"ConflictModal never opened for path '{path}' within 10 s"
    )


async def restore_after_conflict(
    vault_a,
    vault_b,
    cdp_a,
    cdp_b,
    path: str,
) -> None:
    """Remove the seeded file from both vaults and reconcile with the server.

    Deletes the file from both local vaults then triggers a full sync on each
    so the server also removes its copy.  Safe to call even if the file is
    already absent (``missing_ok=True``).
    """
    (vault_a / path).unlink(missing_ok=True)
    (vault_b / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
    await cdp_b.trigger_full_sync()
