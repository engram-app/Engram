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
CRDT_TIMEOUT = DELIVERY_TIMEOUT  # true-breakage bound, not a latency assert


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
# channel fan-out (`note_yjs_update` → applyPushedNoteUpdate). A checkpoint-
# driven backstop on the receiving device also converges a cold note:
# catchupViaSeqReplay's row-apply (applyChange → flushFromCrdt). So if
# applyPushedNoteUpdate were completely broken, every test above would STILL
# pass at ~5s checkpoint latency, masking a dead fan-out.
#
# The tests below pin the fan-out POSITIVELY: cdp.arm_fanout_counter() wraps
# applyPushedNoteUpdate in a pass-through counter, and each test asserts the
# counter moved for its note. A dead fan-out leaves it at zero and fails.
#
# They used to do this by SUPPRESSION — stubbing every backstop to a no-op so
# only the fan-out could satisfy the assert. That never once gave a true answer.
# It stubbed nothing for an unknown span (every name had been retired, and the
# typeof guard skips what is gone), so these four "proofs" ran green with the
# fan-out dead. Fixing that broke the SENDER, because the handler it stubbed is
# what commits noteIdMap (#1503). Fixing THAT left the device with no map repair
# inside the test window (#1526). Counting disables nothing, so none of those
# failure modes exist, and a rename now fails loudly in the helper instead of
# silently making these tests prove nothing. See helpers/cdp.py.


async def _confirm_room_free(cdp, path):
    """Precondition for a fan-out test: the device has mapped + confirmed `path`
    and holds NO CRDT room for it (so convergence can't ride a crdt_msg room
    stream). Returns the note_id.

    trigger_full_sync() drives the idle pull-discovery path, which maps +
    confirms the note but does NOT STEP1-enroll a not-live-bound note via the
    discovery path (sync.ts isLiveBound guard). A checkpoint-driven catch-up
    CAN, however, open a TRANSIENT heal room via the diverged-cold-note
    re-handshake (sync.ts:5578, deliberately un-gated); the plugin releases it
    asynchronously once convergence commits (releaseHealRoom). So wait for that
    release rather than sampling the enrolled set the instant the sync returns —
    a single immediate snapshot races the async release (the source of this
    test's flakiness). A genuinely stuck room still fails via timeout.

    BOTH reads below poll for the same reason. trigger_full_sync() returning
    means the sync call finished, not that the mapping it discovered has landed
    in noteIdMap, so the note_id read raced it exactly as the enrolled-set read
    did — reporting `assert None` ("device never mapped a note_id") for a note
    that maps fine moments later (engram-app/Engram#1489).
    """
    await cdp.wait_for_stream_connected()
    await cdp.trigger_full_sync()
    try:
        note_id = await cdp.wait_for_note_id_for_path(path, timeout=CRDT_TIMEOUT)
    except TimeoutError as e:
        pytest.fail(f"device never mapped a note_id for {path} — cannot prove fan-out — {e}")
    try:
        await cdp.wait_for_room_free(note_id, timeout=CRDT_TIMEOUT)
    except TimeoutError as e:
        pytest.fail(
            f"precondition violated: device holds a CRDT room for idle note {path} "
            f"(note_id={note_id}); convergence could ride crdt_msg, not the fan-out — {e}"
        )
    return note_id


async def _assert_fanout_ran(cdp, note_id, path, minimum=1):
    count = await cdp.fanout_apply_count(note_id)
    assert count >= minimum, (
        f"content converged on {path} but applyPushedNoteUpdate ran {count} time(s) "
        f"for note_id={note_id} (expected >= {minimum}) — the vault-channel fan-out "
        f"did not deliver it; a checkpoint backstop did."
    )


@pytest.mark.asyncio
async def test_idle_note_converges_via_fanout_only(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P0] A pre-existing IDLE note on B converges to A's edit over the vault-
    channel fan-out, and we prove the fan-out is what ran.

    B never opens or edits the note. The counter on B pins that the server's
    `note_yjs_update` broadcast → applyPushedNoteUpdate actually fired, so a
    dead fan-out fails here instead of passing at checkpoint latency.
    """
    path = "E2E/Crdt/FanoutPassive.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "shared base\n", "shared base")
    note_id_b = await _confirm_room_free(cdp_b, path)
    try:
        await cdp_b.arm_fanout_counter()

        write_note(vault_a, path, "shared base\nFANOUT_ONLY\n")
        b_final = wait_for_content(vault_b, path, "FANOUT_ONLY", timeout=CRDT_TIMEOUT)
        assert "shared base" in b_final, f"base content lost on B: {b_final!r}"
        await _assert_fanout_ran(cdp_b, note_id_b, path)
    finally:
        await cdp_b.disarm_fanout_counter()


@pytest.mark.asyncio
async def test_concurrent_cold_edits_survive_over_fanout(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P0] A and B concurrently edit the SAME note while NEITHER opens it. Both
    edits survive on both disks, and both devices took delivery over the fan-out.

    Does NOT weaken test_concurrent_edits_both_survive (which permits a backstop
    to converge); this is the strictly-fan-out variant.
    """
    path = "E2E/Crdt/FanoutMerge.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "shared base\n", "shared base")
    note_id_a = await _confirm_room_free(cdp_a, path)
    note_id_b = await _confirm_room_free(cdp_b, path)
    try:
        await cdp_a.arm_fanout_counter()
        await cdp_b.arm_fanout_counter()

        # Independent edits, close together so neither has seen the other's yet.
        write_note(vault_a, path, "shared base\nFROM_A\n")
        write_note(vault_b, path, "shared base\nFROM_B\n")

        a_final = wait_for_content(vault_a, path, "FROM_B", timeout=CRDT_TIMEOUT)
        b_final = wait_for_content(vault_b, path, "FROM_A", timeout=CRDT_TIMEOUT)
        assert "FROM_A" in a_final and "FROM_B" in a_final, f"A lost an edit: {a_final!r}"
        assert "FROM_A" in b_final and "FROM_B" in b_final, f"B lost an edit: {b_final!r}"
        await _assert_fanout_ran(cdp_a, note_id_a, path)
        await _assert_fanout_ran(cdp_b, note_id_b, path)
    finally:
        await cdp_a.disarm_fanout_counter()
        await cdp_b.disarm_fanout_counter()


@pytest.mark.asyncio
async def test_cold_send_over_fanout_opens_no_room(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    """[P1] B edits a CLOSED note → A receives it over the fan-out, and B does
    NOT STEP1-enroll a CRDT room for the note it cold-sent.

    An idle SEND ships its edit channel-up / as a durable /updates entry and is
    never required to enroll (sync.ts isCrdtManagedOffline: "Enrollment (STEP1)
    is only the down-sync pull, never required to SEND"). The negative half is a
    direct read of B's CrdtEnrollment.enrolled set; the positive half is A's
    fan-out counter.

    This test was the #1 source of e2e-crdt red for weeks, across three distinct
    failure regimes, none of them a real fan-out bug: suppression stubbed nothing
    (false green), then broke B's push via noteIdMap (#1503), then removed B's
    map repair so a transient unmapping burned the full timeout (#1526). All
    three were artifacts of DISABLING paths on a live client. Counting disables
    nothing, so the pre-write mapping re-poll #1526 needed is gone too — nothing
    in the window can drop a mapping that cannot then heal.
    """
    path = "E2E/Crdt/FanoutColdSend.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "origin\n", "origin")
    note_id_b = await _confirm_room_free(cdp_b, path)
    note_id_a = await _confirm_room_free(cdp_a, path)
    try:
        await cdp_a.arm_fanout_counter()

        # B edits the CLOSED note (never opened in the editor).
        write_note(vault_b, path, "origin\nCOLD_SEND_FROM_B\n")

        a_final = wait_for_content(vault_a, path, "COLD_SEND_FROM_B", timeout=CRDT_TIMEOUT)
        assert "origin" in a_final, f"base lost on A: {a_final!r}"
        await _assert_fanout_ran(cdp_a, note_id_a, path)

        enrolled = await cdp_b.get_enrolled_note_ids()
        assert note_id_b not in enrolled, (
            f"B STEP1-enrolled a room for a cold SEND (note_id={note_id_b}); "
            f"an idle send must stay room-free. enrolled={enrolled}"
        )
    finally:
        await cdp_a.disarm_fanout_counter()


@pytest.mark.asyncio
async def test_fanout_sequential_edits_converge_preserving_prior_state(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """[P1] Two SEQUENTIAL remote edits to an idle note both converge on B over
    the fan-out, the second preserving the first.

    (Was ``test_fanout_receive_after_hibernate_rehydrates``: the Relay-model
    persistent-doc engine NEVER frees an idle Y.Doc — ``closeDoc`` /
    ``hibernateIfIdle`` are no-ops now, so there is no free-then-rehydrate step to
    assert. The residual guarantee — a second fan-out apply merges onto the doc
    the first left behind, no state lost — still matters and is what this pins.)

    The counter asserts >= 2: EDIT_ONE is confirmed on B's disk before EDIT_TWO
    is written, so the two applies cannot coalesce into one.
    """
    path = "E2E/Crdt/FanoutSequential.md"
    await _establish_on_both(vault_a, vault_b, cdp_b, api_sync, path, "base\n", "base")
    note_id_b = await _confirm_room_free(cdp_b, path)
    try:
        await cdp_b.arm_fanout_counter()

        # First remote edit converges via the fan-out.
        write_note(vault_a, path, "base\nEDIT_ONE\n")
        wait_for_content(vault_b, path, "EDIT_ONE", timeout=CRDT_TIMEOUT)

        # Second edit merges onto the (still-resident) doc, preserving prior state.
        write_note(vault_a, path, "base\nEDIT_ONE\nEDIT_TWO\n")
        b_final = wait_for_content(vault_b, path, "EDIT_TWO", timeout=CRDT_TIMEOUT)
        assert "EDIT_ONE" in b_final and "base" in b_final, (
            f"second fan-out apply lost prior state: {b_final!r}"
        )
        await _assert_fanout_ran(cdp_b, note_id_b, path, minimum=2)
    finally:
        await cdp_b.disarm_fanout_counter()
