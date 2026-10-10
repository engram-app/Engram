"""First-sync a set of frontmatter shapes and report what the sync did to them.

Shared by test_101 (no conflict copies) and test_102 (disk bytes untouched).
"""

from __future__ import annotations

import json
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from helpers.vault import write_note

CONVERGE_BOUND_S = 90
# Catch-up after the push is what fires the drift branch. Prod drift-copied
# within ~20s of the push sweep; give a few manual syncs room to run it.
CATCH_UP_SETTLE_S = 20


SET_BLOCKED = "app.plugins.plugins['engram-vault-sync'].syncEngine.setSyncBlocked({})"

# A conflict copy needs a THREE-way disagreement: the user's raw bytes, the
# plugin's re-emit and the backend's re-emit must all differ. If the plugin
# reproduces the raw bytes, nothing is rewritten on disk; if the backend does,
# catch-up recognises its own echo. A single-key note rarely trips both, which
# is why a first cut of this fixture passed on the broken build. Real notes
# carry several keys, so each shape mixes one key the BACKEND rewrites (quote
# style) with one the PLUGIN rewrites (null, flow list, comment). Each was
# measured against the real codecs: plugin genesis bytes projected through
# `CrdtBridge.project_doc`.
DRIFTING_SHAPES = {
    "wikilink-and-empty": '---\nup: "[[Home]]"\nstatus:\n---\n',
    "hashtag-and-flow-list": '---\ntag: "#project"\ntags: [a, b]\n---\n',
    "wikilink-and-quoted-title": '---\nup: "[[Home]]"\ntitle: "Hello"\n---\n',
    "colon-and-comment": '---\ntitle: "Meeting: kickoff" # agenda below\n---\n',
    "aliases-flow-wikilinks": '---\naliases: ["[[Alpha]]", "[[Beta]]"]\n---\n',
    "tilde-null": "---\nstatus: ~\n---\n",
    "yes-string": '---\nanswer: "yes"\n---\n',
    # Obsidian's own default layout for an empty list property.
    "obsidian-cssclasses": "---\ncssclasses: \n---\n",
}


@dataclass
class FirstSyncResult:
    prefix: str
    written: dict[str, str]
    conflict_copies: list[str]
    rewritten: dict[str, str]


async def first_sync_shapes(
    vault, cdp, api_sync, shapes: dict[str, str], tag: str
) -> FirstSyncResult:
    prefix = f"{tag}-{uuid.uuid4().hex[:12]}"
    await cdp.evaluate(SET_BLOCKED.format("true"))
    # Record every file the plugin CREATES. A drift-copy cannot be found by
    # scanning disk afterwards: the copy is stamped as synced but never pushed,
    # so the next manifest reconcile reads it as server-deleted and TRASHES it
    # ("Reconcile: server-deleted -> trashed"), within a second.
    await cdp.evaluate(
        "window.__fmCreates = [];"
        "window.__fmCreatesRef = app.vault.on('create', f => window.__fmCreates.push(f.path)); true"
    )

    written: dict[str, str] = {}
    for name, fm in shapes.items():
        body = "\n".join(f"line {j} of {name}" for j in range(20))
        rel = f"{prefix}/{name}.md"
        written[rel] = f"{fm}\n# {name}\n\n{body}\n"
        write_note(vault, rel, written[rel])

    expected = len(written)
    deadline = time.monotonic() + 60
    indexed = 0
    while time.monotonic() < deadline:
        indexed = await cdp.evaluate(
            f"app.vault.getFiles().filter(f => f.path.startsWith('{prefix}/')).length"
        )
        if isinstance(indexed, int) and indexed >= expected:
            break
        time.sleep(1)
    else:
        raise TimeoutError(f"Obsidian indexed only {indexed}/{expected} files")

    await cdp.accept_sync_gate()

    started = time.monotonic()
    landed = 0
    while time.monotonic() < started + CONVERGE_BOUND_S:
        await cdp.evaluate(SET_BLOCKED.format("false"))
        await cdp.trigger_full_sync()
        landed = sum(
            1
            for n in api_sync.get_manifest()["notes"]
            if n["path"].startswith(prefix) and "(conflict" not in n["path"]
        )
        if landed >= expected:
            break
        time.sleep(2)
    assert landed >= expected, f"sync landed only {landed}/{expected}"

    settle_end = time.monotonic() + CATCH_UP_SETTLE_S
    while time.monotonic() < settle_end:
        await cdp.trigger_full_sync()
        time.sleep(4)

    created = await cdp.evaluate(
        "JSON.stringify(window.__fmCreates); app.vault.offref(window.__fmCreatesRef);"
        "JSON.stringify(window.__fmCreates)"
    )
    copies = sorted(
        p
        for p in json.loads(created or "[]")
        if p.startswith(prefix) and "(conflict" in p
    )
    rewritten = {}
    for rel, original in written.items():
        now = Path(vault, rel).read_text(encoding="utf-8")
        if now != original:
            rewritten[rel] = now
    return FirstSyncResult(prefix, written, copies, rewritten)
