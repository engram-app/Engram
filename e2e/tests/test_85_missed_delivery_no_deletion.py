"""Test 85: missed delivery + ignorant local push must NOT delete server content.

Encodes the core 2026-07-07 failure chain (identity-as-CRDT handoff A5b):

  missed delivery → client ignorant → ignorant full-content push
  "convergently" deletes what the client never saw.

B misses a server-side edit (channel down during an API write). B then makes
and pushes its own local edit — a full-content push from a device that has
never seen the server's current content, declaring the stale base it DOES
know. Before the base_hash CAS gate (backend v0.5.642 + plugin v1.11.23) that
push sailed through and silently erased the server edit with no trace.

Pass bar: NEITHER edit silently vanishes. The plugin's auto conflict flow may
legitimately keep local on the server (that's an explicit, surfaced choice —
the server edit survives as a conflict-copy file), or merge; what must never
happen is either marker disappearing from every surface. Afterwards B and the
server converge on the same main-file content.
"""

import asyncio
import uuid

import pytest

from helpers.log_oracle import wait_for_delivery


def _vault_texts(vault_path, folder: str) -> str:
    """Concatenated text of every md file under folder (main file + any
    conflict copies) — the no-content-lost oracle."""
    root = vault_path / folder
    if not root.exists():
        return ""
    return "\n".join(
        p.read_text(encoding="utf-8") for p in sorted(root.rglob("*.md")) if p.is_file()
    )


@pytest.mark.asyncio
async def test_missed_delivery_then_local_push_no_deletion(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    # Rerun-safety: unique path per attempt (fresh identity every run).
    unique = uuid.uuid4().hex[:12]
    folder = f"E2E/MissedDelivery-{unique}"
    path = f"{folder}/Note.md"
    server_marker = f"server-edit-{unique}"
    local_marker = f"local-edit-{unique}"

    # These tests run LAST (highest numbers) and inherit the whole suite's
    # socket churn — the stream can sit mid-backoff at test start (CI run
    # 28936382212: "Stream not connected after 20s"). Force a known-good
    # connection instead of waiting out the backoff timer.
    for cdp in (cdp_a, cdp_b):
        if not await cdp.check_stream_connected():
            await cdp.reconnect_stream()
        await cdp.wait_for_stream_connected(timeout=20)

    # Seed: A creates, B receives — both devices synced on a base version.
    base = f"# Missed Delivery\n\nbase-{unique}\n"
    await cdp_a.push_file_now(path, base)
    wait_for_delivery(vault_b, path, api_sync, timeout=30)

    # B goes deaf: channel down, so the next server-side change is missed.
    # cdp_b is SESSION-scoped: the reconnect must be guaranteed even when an
    # assert/helper raises mid-test, or B stays deaf for every later test
    # (same try/finally convention as test_30/test_48).
    await cdp_b.disconnect_stream()
    await asyncio.sleep(0.3)
    assert not await cdp_b.check_stream_connected(), "B's channel should be down"

    try:
        # A third writer advances the server while B can't hear it.
        api_sync.create_note(path, f"{base}\n{server_marker}\n")
        api_sync.wait_for_note_content(path, server_marker, timeout=15)

        # B, still ignorant of the server edit, makes and pushes its OWN edit
        # through the real plugin write path (vault.modify + pushFile) so the
        # push declares B's stale base_hash. This is the killer push.
        await cdp_b.push_file_now(path, f"{base}\n{local_marker}\n")

        # THE invariant: no silent deletion, in either direction. Whatever the
        # conflict flow chose (409 → conflict copy + keep-local, or merge),
        # both markers must survive on SOME surface: the server note or B's
        # vault (main file or conflict copy). Poll — the conflict flow (409 →
        # copy write) needs a moment under CI load; a fixed sleep flakes.
        server_body = ""
        b_union = ""
        deadline = 20
        while deadline > 0:
            server_body = (api_sync.get_note(path) or {}).get("content", "")
            b_union = _vault_texts(vault_b, folder)
            if (server_marker in server_body or server_marker in b_union) and (
                local_marker in b_union or local_marker in server_body
            ):
                break
            await asyncio.sleep(1)
            deadline -= 1
        assert server_marker in server_body or server_marker in b_union, (
            "the ignorant push silently deleted the server edit "
            f"(server={server_body[:200]!r}, b_union={b_union[:300]!r})"
        )
        assert local_marker in b_union or local_marker in server_body, (
            f"B's local edit vanished (server={server_body[:200]!r}, b_union={b_union[:300]!r})"
        )
    finally:
        # Reconnect unconditionally — the session's later tests need B live.
        await cdp_b.reconnect_stream()

    # Durable end state — the incident invariant this test guards is
    # "no silent deletion + no data loss on EITHER side". Under lazy enrollment a
    # cold (never editor-opened) note holds no live CRDT room, so a genuine
    # conflict cannot character-merge into one main file: it resolves keep-both.
    # B surfaces the server edit it missed (delivered by its own ignorant push's
    # 409, which carries the server body over REST — channel-independent, not the
    # reconnect above; the reconnect just restores live sync for later tests) as a
    # conflict-copy file, its local edit stays as the main file, and the server
    # retains its edit. We do NOT assert single-main convergence (a live-room
    # property, not a cold note's) — that would only pass vacuously here.
    #
    # Three legs, each failing a distinct real regression: the server edit deleted
    # (the ignorant-push clobber), B's local edit lost (a keep-remote overwrite),
    # or B never surfacing the server edit at all (the permanent-miss black hole).
    # Poll: the 409 conflict-copy write can lag the push under CI load.
    deadline = 30
    while deadline > 0:
        b_union = _vault_texts(vault_b, folder)
        server_body = (api_sync.get_note(path) or {}).get("content", "")
        if server_marker in server_body and local_marker in b_union and server_marker in b_union:
            break
        await asyncio.sleep(1)
        deadline -= 1
    assert server_marker in server_body, (
        f"the ignorant push deleted the server edit (server={server_body[:200]!r})"
    )
    assert local_marker in b_union, (
        f"B's local edit was lost to the server edit (b={b_union[:300]!r})"
    )
    assert server_marker in b_union, (
        f"B never surfaced the missed server edit — permanent miss (b={b_union[:300]!r})"
    )
