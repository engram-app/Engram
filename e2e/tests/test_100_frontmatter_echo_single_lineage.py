"""Test 100: frontmatter that does not round-trip must not fork a lineage.

Third narrowing test for the 2026-08-23 double-write, and the one that targets
the remaining gap between the passing e2e runs and the failing production run:

    e2e (test_97/98/99):  0 edit-class rooms, 0 doubled notes
    production:         213 edit-class rooms, 224/316 doubled

An edit-class room means the device emitted a LOCAL-origin update after the
genesis seed. test_99 ruled out a byte-identical echo — that is suppressed. What
is left is a write-back whose bytes genuinely DIFFER from what was read: the
genesis adopt awaits its own `flushFromCrdt`, and if the text the CRDT projects
is not byte-identical to the file on disk, Obsidian's modify event carries a
real diff, `applyLocalEdit` forks a lineage, and the cold `crdt_msg` ships it as
a second full copy.

The suspect is frontmatter normalisation. Every e2e fixture so far used simple
block-style YAML that round-trips exactly; the reporter's vault is full of
inline arrays, quoted scalars, comments and irregular spacing. So the fixtures
here are deliberately round-trip HOSTILE, and the assertion is direct: the bytes
on disk after a sync must equal the bytes written before it.

The fence is the LINEAGE COUNT, not the disk bytes. The rewrite itself is
expected and benign: the CRDT stores frontmatter structurally, so its projection
re-serialises YAML, and writing that back is the authoritative content winning.
What must never follow is a second lineage. The rewrite list is printed rather
than asserted so a future change to the codec shows up as context on a failure
instead of as a failure of its own.

Verified to catch the defect: against the code before
`applyLocalEdit`'s projection-equality guard, this reported 7 of 10 notes
holding 2 lineages and 7 edit-class rooms — one per rewritten file. With the
guard: 0 and 0.
"""

from __future__ import annotations

import time
import uuid
from pathlib import Path

import pytest

from helpers.lineage_probe import read_lineages
from helpers.room_probe import arm_room_starts, read_room_starts
from helpers.vault import write_note

# Must stay well under pytest.ini's 180s timeout. Equal to it, the loop
# can never reach its own assertion — pytest-timeout kills the test first
# and reports a generic timeout instead of "converged only N/M".
CONVERGE_BOUND_S = 90

SET_BLOCKED = (
    "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"
)

# Each shape is a separate way YAML can fail to survive a parse/serialise round
# trip. Named so a failure says WHICH shape moved rather than just "bytes
# differ".
FRONTMATTER_SHAPES = {
    "inline-array": "---\ntags: [alpha, beta, gamma]\n---\n",
    "quoted-scalar": '---\ntitle: "Quoted: with colon"\nstatus: \'single\'\n---\n',
    "comment": "---\ntags:\n  - a\n# a trailing comment\nreviewed: 2026-08-23\n---\n",
    "irregular-space": "---\ntags:\n    - deep\n    - indent\nkey:    spaced\n---\n",
    "nested-map": "---\nmeta:\n  author: todd\n  nested:\n    deeper: true\n---\n",
    "empty-value": "---\nalias:\ntags:\n  - has-empty-sibling\n---\n",
    "date-scalar": "---\ncreated: 2026-08-23\nupdated: 2026-08-23T09:28:41Z\n---\n",
    "numeric-string": '---\nversion: "1.20"\nbuild: 007\n---\n',
    "blank-lines": "---\ntags:\n  - a\n\n\nreviewed: 2026-08-23\n---\n",
    "no-frontmatter": "",
}

# The second echo shape, folded in from what was test_99: a rewrite with
# BYTE-IDENTICAL content. It exercises the same "engine sees its own write come
# back" path but with nothing for the codec to normalise, so it isolates
# suppression that keys on content equality from suppression that keys on
# round-trip stability. Cheap to carry here — it reuses this test's vault pass
# instead of paying for another one.
IDENTICAL_ECHO = "identical-bytes"


@pytest.mark.asyncio
async def test_sync_leaves_disk_bytes_untouched(
    vault_a, cdp_a, api_sync, sync_vault_id
):
    run = uuid.uuid4().hex[:12]
    prefix = f"Roundtrip-{run}"

    arm_room_starts()
    rooms_before = read_room_starts()

    await cdp_a.evaluate(SET_BLOCKED.format("true"))

    written: dict[str, str] = {}
    shapes = {**FRONTMATTER_SHAPES, IDENTICAL_ECHO: "---\ntags:\n  - stable\n---\n"}
    for name, fm in shapes.items():
        body = "\n".join(f"line {j} of {name}" for j in range(40))
        rel = f"{prefix}/{name}.md"
        written[rel] = f"{fm}\n# {name}\n\n{body}\n"
        write_note(vault_a, rel, written[rel])

    expected = len(shapes)
    deadline = time.monotonic() + 60
    indexed = 0
    while time.monotonic() < deadline:
        indexed = await cdp_a.evaluate(
            f"app.vault.getFiles().filter(f => f.path.startsWith('{prefix}/')).length"
        )
        if isinstance(indexed, int) and indexed >= expected:
            break
        time.sleep(1)
    else:
        raise TimeoutError(f"Obsidian indexed only {indexed}/{expected} files")

    await cdp_a.accept_sync_gate()

    started = time.monotonic()
    landed = 0
    while time.monotonic() < started + CONVERGE_BOUND_S:
        await cdp_a.evaluate(SET_BLOCKED.format("false"))
        await cdp_a.trigger_full_sync()
        manifest = api_sync.get_manifest()
        landed = sum(1 for n in manifest["notes"] if n["path"].startswith(prefix))
        if landed >= expected:
            break
        time.sleep(2)
    assert landed >= expected, f"sync landed only {landed}/{expected}"

    # Second echo shape: rewrite one file with its OWN bytes. Nothing for the
    # codec to normalise, so anything this forks is a suppression gap rather
    # than a round-trip artefact.
    identical_rel = f"{prefix}/{IDENTICAL_ECHO}.md"
    Path(vault_a, identical_rel).write_text(written[identical_rel], encoding="utf-8")

    # Give both write-backs and the modify events they trigger time to land.
    time.sleep(10)

    rewritten = {
        rel: Path(vault_a, rel).read_text(encoding="utf-8")
        for rel in written
        if Path(vault_a, rel).read_text(encoding="utf-8") != written[rel]
    }
    lineages = read_lineages(sync_vault_id)
    rooms = read_room_starts() - rooms_before
    print(
        f"\ntest_100 rewritten-on-disk={sorted(rewritten)} | {lineages} | rooms: {rooms}"
    )

    # The rewrite is the TRIGGER, and it is expected — see the module docstring.
    # Asserted only to the extent that it must still be happening, because a run
    # where nothing was rewritten never exercised the path this test exists for
    # and would pass vacuously.
    assert rewritten, (
        "no file was rewritten, so this run never exercised the write-back echo "
        "that the lineage assertion below is fencing. Did the frontmatter codec "
        "start round-tripping byte-for-byte? If so this fixture needs a new "
        "round-trip-hostile shape."
    )

    assert lineages.multi_client == 0, (
        f"frontmatter normalisation forked a lineage: {lineages}. The engine's "
        "own write-back fired a modify with genuinely different bytes, and "
        "handleModify skips its recently-flushed guard for CRDT notes — so the "
        "echo reached applyLocalEdit, which re-set the frontmatter map and "
        f"minted this device as a second client. Rooms: {rooms}."
    )
