"""CRDT file-level sync e2e (spec §12a).

These tests exercise behaviours that are UNIQUE to the CRDT sync path and the
regressions that broke it. They run only when the harness opted the plugin into
CRDT (``E2E_ENABLE_CRDT=true``) against a backend that advertises the ``crdt:``
topic (``CRDT_ENABLED=true``); otherwise they skip.

CRDT-aware assertions: unlike the legacy REST path, a CRDT note is
eventually-consistent. The body is delivered device->device over the
y-protocols handshake and only flushed to ``notes.content`` on the debounced
checkpoint (~5s). So these tests poll the *vault file on disk* (the device-side
source of truth) and the REST content with generous timeouts — never an
immediate read-after-write.
"""

from __future__ import annotations

import os

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import delete_note, wait_for_content, wait_for_file_gone, write_note
from helpers.latency import DELIVERY_TIMEOUT

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

# CRDT delivery = server checkpoint debounce (~5s) + handshake; be generous.
CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound; latency is recorded, not asserted


async def _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, body, marker):
    """Create `path` on A and wait until B has it on disk live — a shared CRDT base.

    No pull backstop: this is the first time `path` exists on B, so the
    delivery oracle's non-empty guard correctly signals arrival.
    """
    write_note(vault_a, path, body)
    api_sync.wait_for_note_content(path, marker, timeout=CRDT_TIMEOUT)
    content = wait_for_delivery(vault_b, path, api_sync, timeout=CRDT_TIMEOUT)
    assert marker in content, f"B never received the shared base for {path}"


@pytest.mark.asyncio
async def test_discovery_creates_file_on_b(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A creates a note B has never had -> the file is CREATED on B's disk.

    Regression: flushFromCrdt returned early when the file didn't exist, so a
    discovered note's body sat in B's Yjs doc but was never written to disk and
    the note stayed permanently invisible on B.
    """
    path = "E2E/Crdt/Discovery.md"
    write_note(vault_a, path, "# Discovery\nbody authored on device A")
    api_sync.wait_for_note_content(path, "device A", timeout=CRDT_TIMEOUT)

    content = wait_for_delivery(vault_b, path, api_sync, timeout=CRDT_TIMEOUT)
    assert "body authored on device A" in content


@pytest.mark.asyncio
async def test_concurrent_edits_both_survive(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A and B independently edit the same note; BOTH edits survive on BOTH
    devices after convergence. This is the defining CRDT property — legacy
    last-write-wins would drop one side.
    """
    path = "E2E/Crdt/Merge.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "shared base\n", "shared base")

    # Independent edits at different positions, applied close together so neither
    # device has seen the other's change yet (true concurrency).
    write_note(vault_a, path, "shared base\nFROM_A\n")
    write_note(vault_b, path, "shared base\nFROM_B\n")

    # Both sides converge live over the y-protocols handshake — no pull
    # backstop. Both files already exist (from the shared base above), so
    # the content-aware poll (not the oracle's non-empty guard) proves the
    # other side's edit actually arrived.
    a_final = wait_for_content(vault_a, path, "FROM_B", timeout=CRDT_TIMEOUT)
    b_final = wait_for_content(vault_b, path, "FROM_A", timeout=CRDT_TIMEOUT)
    assert "FROM_A" in a_final and "FROM_B" in a_final, f"A lost an edit: {a_final!r}"
    assert "FROM_A" in b_final and "FROM_B" in b_final, f"B lost an edit: {b_final!r}"


@pytest.mark.asyncio
async def test_no_conflict_modal_on_divergence(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A divergence that would pop the legacy ConflictModal must merge silently
    under CRDT — no modal is shown (the C1 guard's whole purpose)."""
    path = "E2E/Crdt/NoModal.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "base line\n", "base line")

    write_note(vault_a, path, "base line\nA change\n")
    write_note(vault_b, path, "base line\nB change\n")

    # Wait for the merge to actually converge live before checking for a
    # modal — otherwise "no modal yet" would be a race, not a guarantee.
    wait_for_content(vault_a, path, "B change", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path, "A change", timeout=CRDT_TIMEOUT)

    # No conflict modal open in either app.
    for cdp in (cdp_a, cdp_b):
        modal_count = await cdp.evaluate(
            "document.querySelectorAll('.modal-container .engram-conflict-modal, "
            ".modal .mod-conflict, .engram-conflict-modal').length"
        )
        assert modal_count == 0, "a conflict modal was shown under CRDT"


@pytest.mark.asyncio
async def test_content_reaches_rest_after_checkpoint(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """A CRDT-created note's body eventually lands in REST notes.content (via the
    checkpoint flush) — what the web app / initial pull read. Eventually
    consistent, not immediate."""
    path = "E2E/Crdt/RestFlush.md"
    write_note(vault_a, path, "# RestFlush\ncheckpoint should flush this")
    ok = api_sync.wait_for_note_content(path, "checkpoint should flush", timeout=CRDT_TIMEOUT)
    assert ok, "CRDT content never flushed to REST notes.content"


@pytest.mark.asyncio
async def test_delete_propagates(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """Deleting a CRDT note on A removes it from B (deletes route around the
    C1 guard, not through the CRDT body path)."""
    path = "E2E/Crdt/DeleteMe.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "delete me\n", "delete me")

    delete_note(vault_a, path)
    wait_for_file_gone(vault_b, path, timeout=CRDT_TIMEOUT)


@pytest.mark.asyncio
async def test_edit_after_discovery_round_trips(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """After B discovers a note, an edit B makes flows back to A — proving the
    discovered note is fully CRDT-managed on B, not a one-shot disk write."""
    path = "E2E/Crdt/RoundTrip.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "origin A\n", "origin A")

    write_note(vault_b, path, "origin A\nappended on B\n")

    a_content = wait_for_content(vault_a, path, "appended on B", timeout=CRDT_TIMEOUT)
    assert "origin A" in a_content and "appended on B" in a_content


# ---------------------------------------------------------------------------
# Vault-channel fan-out isolation
# ---------------------------------------------------------------------------
#
# The tests above prove eventual convergence but NOT that it rides the vault-
# channel fan-out (`note_yjs_update` → applyPushedNoteUpdate). Two checkpoint-
# driven backstops on the receiving device also converge a cold note: pull()'s
# cursor-feed backfill (flushFromCrdt) and coldReceive() (invoked at pull()'s
# tail). So if applyPushedNoteUpdate were completely broken, every test above
# would STILL pass at ~5s checkpoint latency, masking a dead fan-out.
#
# The tests below suppress those backstops on the RECEIVING device via
# cdp.suppress_fanout_backstops() (stubs pull, coldReceive AND handleStreamEvent
# — the note_changed room-enroll path — while leaving applyPushedNoteUpdate
# untouched, since the fan-out is a separate channel dispatch). With the
# backstops dead, a disk-convergence assert can ONLY be satisfied by the
# fan-out, so a broken fan-out actually FAILS. See helpers/cdp.py.


async def _confirm_room_free(cdp, path):
    """Precondition for a fan-out isolation test: the device has mapped +
    confirmed `path` and holds NO CRDT room for it (so convergence can't ride a
    crdt_msg room stream). Returns the note_id.

    trigger_full_sync() drives the idle pull-discovery path, which maps +
    confirms the note but does NOT STEP1-enroll a not-live-bound note
    (sync.ts:3790/3820 guards) — so the note stays room-free.
    """
    await cdp.wait_for_stream_connected()
    await cdp.trigger_full_sync()
    note_id = await cdp.get_note_id_for_path(path)
    assert note_id, f"device never mapped a note_id for {path} — cannot prove fan-out"
    enrolled = await cdp.get_enrolled_note_ids()
    assert note_id not in enrolled, (
        f"precondition violated: device holds a CRDT room for idle note {path} "
        f"(note_id={note_id}); convergence could ride crdt_msg, not the fan-out"
    )
    return note_id


@pytest.mark.asyncio
async def test_idle_note_converges_via_fanout_only(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P0] A pre-existing IDLE note on B converges to A's edit via the vault-
    channel fan-out ALONE.

    B never opens or edits the note. Before A's edit we suppress every
    checkpoint-driven backstop on B (pull() cursor-backfill + coldReceive, and
    the note_changed room-enroll path). The ONLY path that can then converge B's
    disk is the server's `note_yjs_update` broadcast → applyPushedNoteUpdate. So
    a broken fan-out FAILS here instead of silently passing at checkpoint latency.
    """
    path = "E2E/Crdt/FanoutPassive.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "shared base\n", "shared base")
    await _confirm_room_free(cdp_b, path)
    try:
        await cdp_b.suppress_fanout_backstops()

        # A edits. With B's backstops dead, delivery can ONLY be the fan-out.
        write_note(vault_a, path, "shared base\nFANOUT_ONLY\n")
        b_final = wait_for_content(vault_b, path, "FANOUT_ONLY", timeout=CRDT_TIMEOUT)
        assert "shared base" in b_final, f"base content lost on B: {b_final!r}"
    finally:
        await cdp_b.restore_fanout_backstops()


@pytest.mark.asyncio
async def test_concurrent_cold_edits_survive_over_fanout(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P0] A and B concurrently edit the SAME note while NEITHER opens it, with
    the checkpoint backstops suppressed on BOTH devices. Both edits survive on
    both disks — proving the CRDT merge rides the vault-channel fan-out, not the
    pull/coldReceive backstop.

    New test — does NOT weaken test_concurrent_edits_both_survive (which permits
    a backstop to converge); this is the strictly-fan-out variant.
    """
    path = "E2E/Crdt/FanoutMerge.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "shared base\n", "shared base")
    await _confirm_room_free(cdp_a, path)
    await _confirm_room_free(cdp_b, path)
    try:
        await cdp_a.suppress_fanout_backstops()
        await cdp_b.suppress_fanout_backstops()

        # Independent edits, close together so neither has seen the other's yet.
        # Each side SENDS via handleModify/pushFile (untouched by suppression) and
        # RECEIVES the other's over the fan-out (applyPushedNoteUpdate merges the
        # remote delta after capturing local disk drift — both edits survive).
        write_note(vault_a, path, "shared base\nFROM_A\n")
        write_note(vault_b, path, "shared base\nFROM_B\n")

        a_final = wait_for_content(vault_a, path, "FROM_B", timeout=CRDT_TIMEOUT)
        b_final = wait_for_content(vault_b, path, "FROM_A", timeout=CRDT_TIMEOUT)
        assert "FROM_A" in a_final and "FROM_B" in a_final, f"A lost an edit: {a_final!r}"
        assert "FROM_A" in b_final and "FROM_B" in b_final, f"B lost an edit: {b_final!r}"
    finally:
        await cdp_a.restore_fanout_backstops()
        await cdp_b.restore_fanout_backstops()


@pytest.mark.asyncio
async def test_cold_send_over_fanout_opens_no_room(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P1] B edits a CLOSED note → A receives it via the fan-out, and B does NOT
    STEP1-enroll a CRDT room for the note it cold-sent.

    An idle SEND ships its edit channel-up / as a durable /updates entry and is
    never required to enroll (sync.ts isCrdtManagedOffline: "Enrollment (STEP1)
    is only the down-sync pull, never required to SEND"). We suppress backstops
    on BOTH devices: on A so its receipt can ONLY be the fan-out, and on B so its
    own checkpoint `note_changed` echo can't drive a RECEIVE-side enroll — the
    enrolled-set assertion then isolates the SEND path. The negative signal is a
    direct read of B's CrdtEnrollment.enrolled set (deterministic, no log-flush
    timing dependency).
    """
    path = "E2E/Crdt/FanoutColdSend.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "origin\n", "origin")
    note_id_b = await _confirm_room_free(cdp_b, path)
    await _confirm_room_free(cdp_a, path)
    try:
        await cdp_a.suppress_fanout_backstops()
        await cdp_b.suppress_fanout_backstops()

        # B edits the CLOSED note (never opened in the editor).
        write_note(vault_b, path, "origin\nCOLD_SEND_FROM_B\n")

        a_final = wait_for_content(vault_a, path, "COLD_SEND_FROM_B", timeout=CRDT_TIMEOUT)
        assert "origin" in a_final, f"base lost on A: {a_final!r}"

        enrolled = await cdp_b.get_enrolled_note_ids()
        assert note_id_b not in enrolled, (
            f"B STEP1-enrolled a room for a cold SEND (note_id={note_id_b}); "
            f"an idle send must stay room-free. enrolled={enrolled}"
        )
    finally:
        await cdp_a.restore_fanout_backstops()
        await cdp_b.restore_fanout_backstops()


@pytest.mark.asyncio
async def test_fanout_receive_after_hibernate_rehydrates(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P1] A fan-out apply frees B's Y.Doc (applyPushedNoteUpdate →
    hibernateIfIdle → closeDoc). A SECOND edit must still converge, proving the
    apply-after-free path re-opens the doc from IndexedDB and merges correctly —
    end to end, no process restart.
    """
    path = "E2E/Crdt/FanoutHibernate.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "base\n", "base")
    note_id = await _confirm_room_free(cdp_b, path)
    try:
        await cdp_b.suppress_fanout_backstops()

        # First remote edit converges via the fan-out, which then hibernates the
        # idle doc after durably recording the head.
        write_note(vault_a, path, "base\nEDIT_ONE\n")
        wait_for_content(vault_b, path, "EDIT_ONE", timeout=CRDT_TIMEOUT)
        await cdp_b.wait_for_crdt_doc_freed(note_id, timeout=CRDT_TIMEOUT)

        # Second edit AFTER the doc was freed — must rehydrate from IndexedDB and
        # merge, preserving the prior state.
        write_note(vault_a, path, "base\nEDIT_ONE\nEDIT_TWO\n")
        b_final = wait_for_content(vault_b, path, "EDIT_TWO", timeout=CRDT_TIMEOUT)
        assert "EDIT_ONE" in b_final and "base" in b_final, (
            f"rehydrated apply lost prior state: {b_final!r}"
        )
    finally:
        await cdp_b.restore_fanout_backstops()
