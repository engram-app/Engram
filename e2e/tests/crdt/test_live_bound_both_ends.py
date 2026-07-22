"""Reproduces p0 engram-app/Engram-obsidian#224: a note LIVE-BOUND in Obsidian's
editor does not converge on a remote edit without a hard restart.

The existing CRDT live tests open the note on only ONE end:
  - test_obsidian_to_web_live: web editor open, Obsidian writes via file.
  - test_web_to_obsidian_live: web editor open, Obsidian receives on disk (its
    editor is NOT open, so its Y.Doc is not live-bound).

The p0 failure only appears when the RECEIVER's editor is OPEN (live-bound):
the catch-up re-handshake can't merge the server's canonical state into an
already-bound Y.Doc, so it diverges, the bounded retry exhausts, and the edit
never lands until a full restart. This test opens the note in Obsidian's
editor BEFORE the remote edit, which is the missing coverage.

D3 gate (single-path CRDT): the paired plugin PR deletes the REST backstop
(restConvergeLiveBound) entirely, so test_deaf_live_bound_note_converges_via_socket_replay
below stages the previously-intermittent wedge DETERMINISTICALLY: room killed
server-side + the note's next vault fan-out dropped, so the note is provably
deaf and only the socket seq-replay re-handshake (gap-heal) can converge it.
The oracle is REST-ABSENCE: no "REST converge" client-log line may touch the
note. A pre-D3 plugin (still leaning on the REST backstop) fails this gate;
a post-D3 plugin with a broken handshake path times out on content.
"""

from __future__ import annotations

import os
import time
from datetime import datetime, timedelta, timezone

import pytest

from helpers.backend_rpc import backend_rpc
from helpers.log_oracle import wait_for_client_log
from helpers.vault import read_note, wait_for_content

pytestmark = pytest.mark.skipif(
    os.environ.get("E2E_ENABLE_CRDT") != "true",
    reason="CRDT-only suite — set E2E_ENABLE_CRDT=true with a CRDT_ENABLED backend",
)

CRDT_TIMEOUT = 30


def _note_id(api_sync, path: str) -> str:
    note = api_sync.wait_for_note(path, timeout=CRDT_TIMEOUT)
    inner = note.get("note", note) if isinstance(note, dict) else {}
    nid = inner.get("id") or inner.get("note_id") or inner.get("uuid")
    assert nid, f"no note id in GET /notes/{path}: {note}"
    return str(nid)


@pytest.mark.asyncio
async def test_remote_edit_converges_while_note_is_live_bound_in_obsidian(
    web, vault_b, cdp_b, api_sync, sync_vault_id
):
    path = "E2E/Crdt/BothLiveBound224.md"

    # Establish the note on B's disk (setup only; trigger_full_sync here is fine
    # because the ASSERTION below uses no full-sync).
    api_sync.create_note(path, "# Both Live Bound\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)

    # THE trigger: open the note in Obsidian's editor so its Y.Doc is LIVE-BOUND
    # when the remote edit arrives (the condition the other tests never set up).
    opened = await cdp_b.evaluate(
        """
        (async () => {
          const f = app.vault.getAbstractFileByPath(%r);
          if (!f) return "no-file";
          await app.workspace.getLeaf(false).openFile(f);
          return app.workspace.activeEditor?.file?.path ?? "no-active";
        })()
        """
        % path,
        await_promise=True,
    )
    assert opened == path, f"failed to live-bind note in Obsidian editor: {opened!r}"

    # Edit from the web SPA over the CRDT channel.
    note_id = _note_id(api_sync, path)
    await web.open_note(note_id, sync_vault_id)
    await web.append("\nEDIT-WHILE-B-LIVE-BOUND\n")

    # B must converge on the LIVE CRDT fan-out alone: the remote edit arrives AND
    # the preserved base survives the live-bound merge. No catch-up is driven.
    #
    # This previously fell back to `trigger_full_sync()` when the base went
    # missing, asserting only the EVENTUALLY-converged state that the catch-up
    # backstop guarantees (Engram-obsidian#256, a live-merge race that reproduces
    # only under the CI runners' parallel churn). That fallback is gone: the
    # backstop it leaned on (catchUp -> restConvergeLiveBound) is REST, and the
    # sync path is converging on ONE socket CRDT path — a test that heals itself
    # over REST permanently hides live-path data loss, which is the very class of
    # bug #256 is. The live path is the product guarantee, so assert it directly.
    #
    # Engram-obsidian#256 fix: the 3s drift repair could truncate a live-bound
    # editor down to an orphaned/empty Y.Text (base deleted, then autosaved); it
    # now rebinds instead. If this test goes red under churn, that is the
    # reproduction that never surfaced locally — look for the client log line
    # `drift repair SKIPPED` to tell a healed orphan apart from a second,
    # still-unknown mechanism. That line ships over the client-log endpoint
    # (`api_sync.get_logs()`, the source helpers/log_oracle.py mines), NOT the
    # `plugin.log` CI artifact, which is build output only.
    #
    # Wait for each marker separately: `wait_for_content` returns the snapshot at
    # the instant its own marker appears, and the live path may materialize the
    # edit and the base in two flushes. Waiting for base separately asserts the
    # CONVERGED state instead of one instant, without driving a catch-up.
    wait_for_content(vault_b, path, "EDIT-WHILE-B-LIVE-BOUND", timeout=CRDT_TIMEOUT)
    final = wait_for_content(vault_b, path, "base line", timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base content lost on B via the LIVE path: {final!r}"
    assert "EDIT-WHILE-B-LIVE-BOUND" in final, f"remote edit lost on B: {final!r}"


@pytest.mark.asyncio
async def test_deaf_live_bound_note_converges_via_socket_replay(vault_b, cdp_b, api_sync):
    """D3 gate (single-path CRDT): the 2026-07-14 deaf-note class heals over
    the SOCKET alone — no REST converge, no full sync.

    Stage: X live-bound in B's editor; X's server room killed (B silently no
    longer an observer — the prod deafness) AND every vault fan-out for X in
    the window swallowed (FanoutPacer.test_drop_next — the lost-broadcast
    class). A REST edit to X then materializes server-side with a bumped
    vault seq B never sees; a trigger edit to Y delivers a later seq, B
    detects it is behind, and the seq replay's live-bound leg re-handshakes
    (STEP1 recreates the room, STEP2 commits the missing ops — logged
    "socket converge: STEP2 committed <path>"). Convergence may also ride a
    later idle full-state fan-out for X (also socket, also swallowed by the
    generous drop count above) — the gate's oracle is split: presence of a
    socket-converge line for X, and absence of the live-bound REST backstop's
    line for X specifically (the aggregated logs legitimately carry an
    unrelated REST catch-up line for A's cold copy of X, which is not this
    backstop and must not trip the gate).

    Presence assertions are scoped to a baseline captured right AFTER staging
    the wedge (before X's append): live-binding X above fires its own
    healNoteOnOpen "socket converge" line for X BEFORE the wedge even exists,
    which would otherwise satisfy the presence oracle without the replay leg
    ever running.

    A pre-D3 plugin (still leaning on the REST backstop) never logs "socket
    converge" for X post-wedge and fails the presence oracle, and would also
    trip the live-bound-backstop absence line; a post-D3 plugin with a broken
    handshake path times out on content.
    """
    path_x = "E2E/Crdt/DeafLiveBound.md"
    path_y = "E2E/Crdt/DeafLiveTrigger.md"

    api_sync.create_note(path_x, "# Deaf Live Bound\nbase line.\n")
    api_sync.create_note(path_y, "# Deaf Live Trigger\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path_x, "base line", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path_y, "base line", timeout=CRDT_TIMEOUT)

    # Live-bind X in B's editor BEFORE the wedge, so B's Y.Doc owns it.
    opened = await cdp_b.evaluate(
        """
        (async () => {
          const f = app.vault.getAbstractFileByPath(%r);
          if (!f) return "no-file";
          await app.workspace.getLeaf(false).openFile(f);
          return app.workspace.activeEditor?.file?.path ?? "no-active";
        })()
        """
        % path_x,
        await_promise=True,
    )
    assert opened == path_x, f"failed to live-bind note in Obsidian editor: {opened!r}"

    note_id_x = _note_id(api_sync, path_x)
    # Stage the deafness: room dead (B silently unobserved) + next fan-out lost.
    backend_rpc(f'Engram.Notes.CrdtRegistry.terminate_room("{note_id_x}")')
    # generous: swallow EVERY fan-out for X in the window — emit-count drift must
    # not leak a seq-bearing frame (fence-mask class); replay rows are not
    # fan-outs and are unaffected
    backend_rpc(f'Engram.Notes.FanoutPacer.test_drop_next("{note_id_x}", 10)')

    # Baseline AFTER staging, BEFORE the X append: scopes the presence oracles
    # below to post-wedge lines (see docstring — live-binding X above already
    # logged its own pre-wedge "socket converge" line).
    #
    # Stored client-log ts is TRUNCATED to whole seconds (Logs.parse_ts) and
    # the /logs?since= filter is strictly-greater, so a heal line stamped in
    # the SAME second as a microsecond baseline gets floored below it and
    # silently dropped (run 29900728387: heal at :25.522 stored as :25 failed
    # `> :25.3`, oracle timed out with the line present). Separate the epochs
    # by 2s, then floor the baseline and back off one whole second: pre-wedge
    # lines are now strictly older than the baseline second, post-wedge lines
    # strictly newer.
    time.sleep(2)
    post_wedge = (
        datetime.now(timezone.utc).replace(microsecond=0) - timedelta(seconds=1)
    ).isoformat()

    api_sync.append_note(path_x, "\nEDIT-WHILE-B-DEAF\n")
    api_sync.wait_for_note_content(path_x, "EDIT-WHILE-B-DEAF", timeout=CRDT_TIMEOUT)
    # Trigger: Y's delivered fan-out carries a later vault seq — B is provably
    # behind and must self-heal. NO trigger_full_sync from here on.
    api_sync.append_note(path_y, "\nTRIGGER-EDIT-Y\n")

    final = wait_for_content(vault_b, path_x, "EDIT-WHILE-B-DEAF", timeout=CRDT_TIMEOUT)
    assert "base line" in final, f"base content lost on B: {final!r}"
    wait_for_content(vault_b, path_y, "TRIGGER-EDIT-Y", timeout=CRDT_TIMEOUT)

    # Mechanism oracles. get_logs aggregates BOTH devices, and the user's other
    # device (A) legitimately heals its cold (not-live-bound) copy of X via the
    # REST catch-up leg until Phase E deletes it — so the absence assert targets
    # the LIVE-BOUND REST backstop's line specifically (deleted in the paired
    # plugin PR; only a regression can re-emit it), and the presence asserts pin
    # B's heal to the socket primitive (only a live-bound diverged note logs
    # "socket converge", and only B has X bound). All three are scoped to
    # `post_wedge` so the live-bind step's own pre-wedge open-heal line can't
    # satisfy them.
    wait_for_client_log(api_sync, "gap-heal fired", timeout=CRDT_TIMEOUT, after=post_wedge)
    wait_for_client_log(
        api_sync, "socket converge", path_x, timeout=CRDT_TIMEOUT, after=post_wedge
    )
    wait_for_client_log(
        api_sync,
        "socket converge: STEP2 committed",
        path_x,
        timeout=CRDT_TIMEOUT,
        after=post_wedge,
    )
    logs = api_sync.get_logs(limit=1000).get("logs", [])
    rest_lines = [
        log["message"]
        for log in logs
        if "REST converge: live-bound" in log.get("message", "")
        and path_x in log.get("message", "")
    ]
    assert not rest_lines, f"live-bound REST backstop ran for {path_x}: {rest_lines}"


@pytest.mark.asyncio
async def test_deaf_note_survives_handshake_rate_limit_and_heals_on_restore(
    vault_b, cdp_b, api_sync
):
    """Graceful degradation + recovery, socket-only design (E1).

    The deleted REST backstop (restConvergeLiveBound) used to guarantee a
    deaf live-bound note converged even when every channel-heal attempt was
    rate-limited. With the backstop gone, that class of coverage — bounded
    behavior under rate limiting, heal on budget restore — has to be pinned
    directly: this test proves a deaf note does NOT falsely converge while
    the handshake budget is zero (no silent data loss, no fake success), and
    then converges on the very next heal poke once the budget is restored.
    No trigger_full_sync, no Obsidian restart, ever.
    """
    path_x = "E2E/Crdt/DeafLiveBoundRateLimited.md"
    path_y = "E2E/Crdt/DeafLiveBoundRateLimitedTrigger.md"

    api_sync.create_note(path_x, "# Deaf Live Bound Rate Limited\nbase line.\n")
    api_sync.create_note(path_y, "# Deaf Live Bound Rate Limited Trigger\nbase line.\n")
    await cdp_b.trigger_full_sync()
    wait_for_content(vault_b, path_x, "base line", timeout=CRDT_TIMEOUT)
    wait_for_content(vault_b, path_y, "base line", timeout=CRDT_TIMEOUT)

    # Live-bind X in B's editor BEFORE the wedge, so B's Y.Doc owns it.
    opened = await cdp_b.evaluate(
        """
        (async () => {
          const f = app.vault.getAbstractFileByPath(%r);
          if (!f) return "no-file";
          await app.workspace.getLeaf(false).openFile(f);
          return app.workspace.activeEditor?.file?.path ?? "no-active";
        })()
        """
        % path_x,
        await_promise=True,
    )
    assert opened == path_x, f"failed to live-bind note in Obsidian editor: {opened!r}"

    note_id_x = _note_id(api_sync, path_x)
    # Stage the deafness: room dead (B silently unobserved) + next fan-out lost.
    backend_rpc(f'Engram.Notes.CrdtRegistry.terminate_room("{note_id_x}")')
    # generous: swallow EVERY fan-out for X in the window — emit-count drift must
    # not leak a seq-bearing frame (fence-mask class); replay rows are not
    # fan-outs and are unaffected
    backend_rpc(f'Engram.Notes.FanoutPacer.test_drop_next("{note_id_x}", 10)')

    # Zero the handshake budget so every STEP1 re-handshake is rate-limited —
    # the channel-heal path cannot self-heal until the budget is restored.
    # Capture the pre-test override (the CI stack deliberately raises it,
    # #999) so the restore puts back the configured value, not a bare default.
    prior = backend_rpc(
        "IO.puts(inspect(Application.get_env(:engram, :crdt_hs_rate_limit_override)))"
    ).strip()
    backend_rpc("Application.put_env(:engram, :crdt_hs_rate_limit_override, 0)")
    try:
        api_sync.append_note(path_x, "\nEDIT-WHILE-B-DEAF-RATE-LIMITED\n")
        api_sync.wait_for_note_content(
            path_x, "EDIT-WHILE-B-DEAF-RATE-LIMITED", timeout=CRDT_TIMEOUT
        )
        # Trigger: Y's fan-out delivers a later seq, B detects it is behind and
        # attempts a heal — which must be rejected while the budget is zero.
        api_sync.append_note(path_y, "\nTRIGGER-EDIT-Y-1\n")
        wait_for_content(vault_b, path_y, "TRIGGER-EDIT-Y-1", timeout=CRDT_TIMEOUT)

        # Bounded behavior: give the (blocked) heal attempt a full window, then
        # assert X did NOT converge — the deafness is real while the budget is
        # zero, not a false "eventually consistent" success.
        time.sleep(8)
        stuck = read_note(vault_b, path_x)
        assert "EDIT-WHILE-B-DEAF-RATE-LIMITED" not in stuck, (
            f"X converged despite a zeroed handshake budget (false success): {stuck!r}"
        )

        # Recovery: restore the budget explicitly (not deferred to `finally`)
        # — what follows is under test, not cleanup.
        backend_rpc(
            f"Application.put_env(:engram, :crdt_hs_rate_limit_override, {prior})"
        )

        # Budget restored: stage a fresh X row (its fan-out is still swallowed
        # by the armed drops) plus a delivered Y trigger carrying the later
        # seq — the gap-heal replay then re-serves X and the live-bound leg's
        # STEP1 must converge it over the socket. Y alone is NOT enough: X's
        # original row was consumed (rate-limited) during the zero-budget
        # phase and the cursor advanced past it, so a replay without a fresh
        # X row never re-runs X's converge leg within the window (the only
        # other retry path is the periodic manifest heal — nondeterministic).
        api_sync.append_note(path_x, "\nPOST-RESTORE-X\n")
        api_sync.wait_for_note_content(path_x, "POST-RESTORE-X", timeout=CRDT_TIMEOUT)
        api_sync.append_note(path_y, "\nTRIGGER-EDIT-Y-2\n")

        # 2x CRDT_TIMEOUT, deliberately: recovery's DESIGNED latency floor is
        # the plugin's heal cooldown (healCooldownMs=15s) — the zero-budget
        # phase legitimately stamps a fire, so the post-restore heal may be a
        # trailing-coalesce fire up to 15s later, plus STEP2 + editor flush.
        # A 30s window sits barely above that floor and flakes under CI churn
        # (run 29907885751); 60s asserts the same exact content with real
        # margin over the intended latency, not a loosened oracle.
        final = wait_for_content(
            vault_b, path_x, "EDIT-WHILE-B-DEAF-RATE-LIMITED", timeout=2 * CRDT_TIMEOUT
        )
        assert "base line" in final, f"base content lost on B: {final!r}"
        wait_for_content(vault_b, path_y, "TRIGGER-EDIT-Y-2", timeout=CRDT_TIMEOUT)
    finally:
        # Safety net: if anything above raised before the explicit restore
        # ran, the budget must not leak zeroed into later tests.
        backend_rpc(
            f"Application.put_env(:engram, :crdt_hs_rate_limit_override, {prior})"
        )
