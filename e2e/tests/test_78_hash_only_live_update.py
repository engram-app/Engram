"""Test 78: hash-compare live sync — updates apply, identical re-pushes are inert.

Protocol rev: note_changed broadcasts carry content_hash (dual-field for
one release). The plugin compares the hash to its stored per-path
serverHash before touching the vault:

  * differing hash → the change applies (inline content or body fetch)
  * identical hash (e.g. a same-content re-push bumping the version) →
    no vault write, no conflict file

Every wait is explicit with generous timeouts — this is the surface of
flake issue #547 (note-live-update), re-covered here deterministically.
"""

import time

import pytest

from helpers.vault import wait_for_content, wait_for_file

PATH = "E2E/HashOnlyLive.md"


@pytest.mark.asyncio
async def test_hash_only_live_update(vault_b, cdp_b, api_sync):
    # Rerun-safety: pytest-rerunfailures (reruns=1) retries on failure against a
    # SHARED server DB with no reset between attempts. A note left over from a
    # failed attempt 1 makes attempt 2's identical create hit the server's
    # deliberate hash-equal broadcast-skip (an idempotent re-push is a no-op —
    # no version bump, no note_changed), so B never gets the live event and
    # wait_for_file times out. That makes the rerun DETERMINISTICALLY fail
    # rather than retry. Soft-delete first so every attempt's create is a fresh,
    # broadcasting insert. (Same rerun-safety pattern as test_79/test_80.)
    api_sync.delete_note(PATH)

    # Explicit precondition: B's channel must be up before we broadcast.
    await cdp_b.wait_for_stream_connected(timeout=20)

    # 1. Create via API → B receives the broadcast and materializes the file.
    api_sync.create_note(PATH, "# HashLive v1\n\noriginal body")
    content = wait_for_file(vault_b, PATH, timeout=30)
    assert "HashLive v1" in content

    # 2. Update via API → differing content_hash → B applies the new body.
    api_sync.create_note(PATH, "# HashLive v2\n\nupdated body")
    wait_for_content(vault_b, PATH, "HashLive v2", timeout=30)

    # 3. Re-push the IDENTICAL content (server bumps version, hash unchanged).
    #    B's hash compare must treat the broadcast as a no-op: same content,
    #    no conflict copy spawned.
    before_mtime = (vault_b / PATH).stat().st_mtime
    api_sync.create_note(PATH, "# HashLive v2\n\nupdated body")
    api_sync.wait_for_note_content(PATH, "updated body", timeout=15)

    # Give the broadcast time to arrive and (correctly) be ignored.
    time.sleep(5)

    content = (vault_b / PATH).read_text(encoding="utf-8")
    assert "HashLive v2" in content, "identical re-push corrupted the local file"

    conflict_copies = list((vault_b / "E2E").glob("HashOnlyLive (conflict*"))
    assert conflict_copies == [], f"identical re-push spawned conflicts: {conflict_copies}"

    after_mtime = (vault_b / PATH).stat().st_mtime
    assert after_mtime == before_mtime, (
        "identical re-push rewrote the local file — hash compare didn't skip"
    )
