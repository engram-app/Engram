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

Deliberately NOT asserted: which racer's content wins. A REST create with no
base_hash is by contract a full-content overwrite, so the second blind create
replacing the first is current designed behavior (the CAS gate covers pushes
that DECLARE a base). Whether create-vs-create should conflict-copy instead
is a filed design question, not this test's bar.
"""

import asyncio
import uuid

import pytest

from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_content


@pytest.mark.asyncio
async def test_create_race_adopts_winner_and_receives(vault_a, vault_b, cdp_a, cdp_b, api_sync):
    # Rerun-safety: unique path per attempt — a leftover note from a failed
    # attempt would turn the race's create into an update and dodge the
    # two-mint scenario entirely (see e2e-delivery-flake-playbook).
    unique = uuid.uuid4().hex[:12]
    path = f"E2E/CreateRace-{unique}/Raced.md"

    await cdp_a.wait_for_stream_connected(timeout=20)
    await cdp_b.wait_for_stream_connected(timeout=20)

    # The race: an API writer (the MCP/web stand-in) and plugin A create the
    # same path concurrently. push_file_now drives the real pushFile path —
    # mint, push, adopt — while the API create mints the server's own id.
    await asyncio.gather(
        asyncio.to_thread(api_sync.create_note, path, f"# Raced\n\napi-content-{unique}\n"),
        cdp_a.push_file_now(path, f"# Raced\n\nplugin-content-{unique}\n"),
    )

    # One live identity for the path, and a bystander device materializes it.
    note = api_sync.wait_for_note(path, timeout=15)
    assert note is not None
    wait_for_delivery(vault_b, path, api_sync, timeout=30)

    # THE incident pin: A's receive path must be alive after the race. Before
    # plugin #197 the loser kept its dead local mint, so this API edit would
    # announce under the winner id and never materialize on A (delivery
    # latency masked it until a full pull; the live window stayed silent).
    followup = f"followup-edit-{unique}"
    api_sync.create_note(path, f"# Raced\n\n{followup}\n")
    api_sync.wait_for_note_content(path, followup, timeout=15)

    a_content = wait_for_content(vault_a, path, followup, timeout=30)
    b_content = wait_for_content(vault_b, path, followup, timeout=30)
    assert followup in a_content and followup in b_content, (
        "a raced device is cross-wired: the post-race API edit did not arrive "
        f"(a={a_content[:200]!r}, b={b_content[:200]!r})"
    )
