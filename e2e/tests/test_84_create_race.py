"""Test 84: create-race — two writers create the SAME path near-simultaneously.

Encodes the 2026-07-07 production incident (identity-as-CRDT handoff A5a):
an API/MCP writer and the plugin both create one path within the plugin's
debounce window, minting two identities for one note. The server keeps one id
and echoes the winner in the push response; the plugin must ADOPT it (plugin
PR #197). Before that fix the loser stayed cross-wired: its SENDS worked
(REST is path-keyed) but its RECEIVES were dead (announces are keyed by the
server id the plugin never learned) — the note looked synced until another
writer's edit silently never arrived, and the plugin's next ignorant push
overwrote it.

Pass bar (the incident's regression surface):
  1. exactly one live identity for the path; both devices converge, no restart;
  2. the RECEIVE path on the racing device stays alive: a subsequent API edit
     must arrive on BOTH devices (this is what cross-wiring kills).

Deliberately NOT asserted: which racer's content wins. Since Engram#2480 an
API-key create with no base_hash may NOT replace an existing note: if the
plugin's create lands first, the API create gets 409 and the plugin's note
stands; if the API create lands first, the plugin's push merges as before.
Both are correct race outcomes, so the API leg accepts 200 or 409.
"""

import asyncio
import time
import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import wait_for_delivery
from helpers.quiescence import await_quiescent
from helpers.vault import wait_for_content


def wait_until_settled(api_sync, path: str, vaults, timeout: float = DELIVERY_TIMEOUT) -> None:
    """Poll until the server and every vault hold one identical text."""
    deadline = time.monotonic() + timeout
    server = disks = None
    while time.monotonic() < deadline:
        server = api_sync.get_note(path)["content"]
        disks = [(v / path).read_text(encoding="utf-8") for v in vaults]
        if all(disk == server for disk in disks):
            return
        time.sleep(0.2)
    raise AssertionError(f"race never settled: server={server!r} disks={disks!r}")


@pytest.mark.asyncio
async def test_create_race_adopts_winner_and_receives(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    # Rerun-safety: unique path per attempt — a leftover note from a failed
    # attempt would turn the race's create into an update and dodge the
    # two-mint scenario entirely (see e2e-delivery-flake-playbook).
    unique = uuid.uuid4().hex[:12]
    path = f"E2E/CreateRace-{unique}/Raced.md"

    # These tests run LAST (highest numbers) and inherit the whole suite's
    # socket churn — the stream can sit mid-backoff at test start (CI run
    # 28936382212: "Stream not connected after 20s"). Force a known-good
    # connection instead of waiting out the backoff timer.
    for cdp in (cdp_a, cdp_b):
        if not await cdp.check_stream_connected():
            await cdp.reconnect_stream()
        await cdp.wait_for_stream_connected()

    # The race: an API writer (the MCP/web stand-in) and plugin A create the
    # same path concurrently. push_file_now drives the real pushFile path —
    # mint, push, adopt — while the API create mints the server's own id.
    # The API leg is a blind create (no base_hash). If plugin A's create lands
    # first, the server refuses it with 409 (Engram#2480: an API key must not
    # replace a note it never read), and A's note stands. Either outcome is a
    # correct race result, so the leg accepts 200 or 409. Any other status
    # (a transient 429/5xx) still fails the gather: suspect rate-limit
    # starvation, not the race itself.
    def api_create() -> int:
        resp = api_sync.session.post(
            f"{api_sync.base_url}/notes",
            json={
                "path": path,
                "content": f"# Raced\n\napi-content-{unique}\n",
                "mtime": time.time(),
            },
            timeout=10,
        )
        assert resp.status_code in (200, 409), f"API create: {resp.status_code} {resp.text[:200]}"
        return resp.status_code

    await asyncio.gather(
        asyncio.to_thread(api_create),
        cdp_a.push_file_now(path, f"# Raced\n\nplugin-content-{unique}\n"),
    )

    # One live identity for the path, and a bystander device materializes it.
    note = api_sync.wait_for_note(path)
    assert note is not None
    wait_for_delivery(vault_b, path, api_sync)

    # push_file_now resolves once the edit is in A's doc, not once the server
    # has it, so it can land between the follow-up's GET and POST. That 409 is
    # correct (Engram#2541). Wait for A's outbound queues to drain, then for
    # the server and both disks to agree: A's write is on A's disk, so the
    # server only matches once it has it (or A took the server's text).
    await await_quiescent(cdp_a, api_sync, kick=False, caught_up=False)
    wait_until_settled(api_sync, path, (vault_a, vault_b))

    # THE incident pin: A's receive path must be alive after the race. Before
    # plugin #197 the loser kept its dead local mint, so this API edit would
    # announce under the winner id and never materialize on A (delivery
    # latency masked it until a full pull; the live window stayed silent).
    followup = f"followup-edit-{unique}"
    api_sync.create_note(path, f"# Raced\n\n{followup}\n", overwrite=True)
    api_sync.wait_for_note_content(path, followup)

    a_content = wait_for_content(vault_a, path, followup)
    b_content = wait_for_content(vault_b, path, followup)
    assert followup in a_content and followup in b_content, (
        "a raced device is cross-wired: the post-race API edit did not arrive "
        f"(a={a_content[:200]!r}, b={b_content[:200]!r})"
    )
