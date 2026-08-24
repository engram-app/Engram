"""Test 98: re-syncing the SAME local vault into a FRESH server vault must not
double the content.

This is the workflow that produced the 2026-08-23 corruption. The reporter's
words: "I create a new vault for every test." The local Obsidian vault stays put
across those runs, so the device keeps its IndexedDB Y.Docs and its NoteIdMap,
while the server side starts empty every time.

test_97 covers the clean case — a first sync from a device that has never seen
these notes — and it PASSES. The defect needs the asymmetry this test creates:

    device:  already holds a lineage for every path
    server:  brand new vault, knows nothing

That asymmetry is what makes the genesis gate's "does this device have history"
question answer TRUE while the server still needs a full body, and it is the
only material difference between the passing e2e and the failing real run.

Related prior art, same asymmetry, different symptom: the cross-vault id re-mint
in `do_bare_insert` (writes global, reads vault-scoped) — see
docs/context/crdt-wrong-mint-cross-file-overwrite.md.

Asserts on lineage COUNT, not bytes, for the reasons in `lineage_probe`: the two
insertions sometimes interleave rather than concatenate, and viewing a note
heals it.
"""

from __future__ import annotations

import time
import uuid

import pytest

from helpers.billing import grant_vault_headroom
from helpers.lineage_probe import read_lineages
from helpers.vault import write_note

NOTE_COUNT = 10
# Must stay well under pytest.ini's 180s timeout. Equal to it, the loop
# can never reach its own assertion — pytest-timeout kills the test first
# and reports a generic timeout instead of "converged only N/M".
CONVERGE_BOUND_S = 90

SET_BLOCKED = (
    "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"
)

# Re-point the running plugin at a different server vault WITHOUT touching the
# local vault directory — the device's docs and id map must survive, because
# their survival is the precondition under test.
# One expression returning a STRING: the CDP helper serialises objects to `{{}}`,
# which silently reads as "the re-point did nothing".
REPOINT = (
    "(async () => {{ const p = app.plugins.plugins['engram-vault-sync']; "
    'p.settings.vaultId = "{vault_id}"; await p.saveSettings(); '
    'p.api.setVaultId("{vault_id}"); return String(p.settings.vaultId); }})()'
)


async def _converge(cdp, api, prefix, expected):
    started = time.monotonic()
    landed = 0
    while time.monotonic() < started + CONVERGE_BOUND_S:
        await cdp.evaluate(SET_BLOCKED.format("false"))
        await cdp.trigger_full_sync()
        manifest = api.get_manifest()
        landed = sum(1 for n in manifest["notes"] if n["path"].startswith(prefix))
        if landed >= expected:
            break
        time.sleep(2)
    return landed


@pytest.mark.asyncio
async def test_resync_into_fresh_vault_keeps_one_lineage(
    vault_a, cdp_a, api_sync, sync_vault_id, sync_user
):
    run = uuid.uuid4().hex[:12]
    prefix = f"Resync-{run}"

    # Opt in to a second vault for THIS user only. Free caps `vaults_cap` at
    # 1, and lifting it globally in TEST_USER_OVERRIDES broke
    # test_32_vault_api_key_isolation, which asserts Free blocks exactly this.
    grant_vault_headroom(sync_user[0])

    await cdp_a.evaluate(SET_BLOCKED.format("true"))

    # Mixed sizes: the production doubling ran from 17 KB to 68 KB per note, and
    # two lineages over a very short note can merge into one run and hide the
    # structure a larger note exposes.
    # Frontmatter included: the doubling has a frontmatter-only variant (see
    # test_97's fixture comment), and the reporter's first recovered example was
    # a duplicated YAML block, not a duplicated body.
    for i in range(NOTE_COUNT):
        body = "\n".join(f"line {j} of note {i} in {run}" for j in range(i * 12 + 10))
        fm = f"---\ntags:\n  - resync\n  - n{i}\nreviewed: 2026-08-23\n---\n\n"
        write_note(vault_a, f"{prefix}/N{i:03d}.md", f"{fm}# Note {i}\n\n{body}\n")

    deadline = time.monotonic() + 60
    indexed = 0
    while time.monotonic() < deadline:
        indexed = await cdp_a.evaluate(
            f"app.vault.getFiles().filter(f => f.path.startsWith('{prefix}/')).length"
        )
        if isinstance(indexed, int) and indexed >= NOTE_COUNT:
            break
        time.sleep(1)
    else:
        raise TimeoutError(f"Obsidian indexed only {indexed}/{NOTE_COUNT} files")

    await cdp_a.accept_sync_gate()

    # --- sync #1: establishes device-side lineage for every path --------------
    landed = await _converge(cdp_a, api_sync, prefix, NOTE_COUNT)
    assert landed >= NOTE_COUNT, f"first sync landed only {landed}/{NOTE_COUNT}"

    first = read_lineages(sync_vault_id)
    assert first.multi_client == 0, (
        f"the FIRST sync already doubled: {first}. That is test_97's scenario, "
        "so fix that before reading anything into this test."
    )

    # --- swap the server vault, keep the device exactly as it is --------------
    fresh_client = f"resync-{run}"
    resp, status = api_sync.register_vault(f"e2e-resync-{run}", fresh_client)
    fresh_vault = resp.get("vault", resp) if isinstance(resp, dict) else {}
    fresh_id = fresh_vault.get("id") or fresh_vault.get("vault_id")
    assert fresh_id, f"could not register a fresh vault (status={status}): {resp}"
    assert fresh_id != sync_vault_id, "register returned the SAME vault — not a re-sync"

    # await_promise: cdp.evaluate defaults to False, which hands back the
    # unresolved Promise and serialises to `{}` — indistinguishable from a
    # re-point that silently did nothing.
    got = await cdp_a.evaluate(REPOINT.format(vault_id=fresh_id), await_promise=True)
    assert got == fresh_id, f"plugin did not re-point (settings.vaultId={got!r})"

    # --- sync #2: same disk, same device docs, empty server vault -------------
    # Restored in `finally`: `obsidian_a`/`vault_a` are SESSION-scoped, so a
    # plugin left pointing at this throwaway vault silently redirects every
    # later test in the worker — they then sync into a vault their fixtures
    # never read and report "landed 0/N" with no hint why.
    try:
        api_fresh = api_sync.with_vault(fresh_id)
        landed2 = await _converge(cdp_a, api_fresh, prefix, NOTE_COUNT)
        assert landed2 >= NOTE_COUNT, (
            f"re-sync landed only {landed2}/{NOTE_COUNT} into the fresh vault — "
            "the lineage assertion below would be measuring a partial sync"
        )

        second = read_lineages(fresh_id)
        # Printed, not just asserted: a lineage count of 0/0 satisfies
        # `multi_client == 0` vacuously, so the note total has to be visible in
        # the run output for the pass to mean anything.
        print(f"\ntest_98 vault1={first} | fresh vault={second}")
        assert second.notes >= NOTE_COUNT, (
            f"the fresh vault only holds {second.notes} notes — the re-sync did "
            "not land, so the lineage assertion below would pass vacuously"
        )

        assert second.multi_client == 0, (
            f"re-syncing an unchanged vault into a fresh server vault produced "
            f"{second}. Two lineages means the server holds the document twice "
            "while disk holds it once; the client cannot see it because opening "
            "a note converges it back down."
        )
    finally:
        await cdp_a.evaluate(
            REPOINT.format(vault_id=sync_vault_id), await_promise=True
        )
