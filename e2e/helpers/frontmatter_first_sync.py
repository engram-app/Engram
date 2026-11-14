"""First-sync a set of frontmatter shapes and report what the sync did to them.

Used by test_101 (no conflict copies). The red test_102 (disk bytes untouched)
lives on branch `test/frontmatter-fidelity-repro` until #1928 fix 2 lands.
"""

from __future__ import annotations

import asyncio
import re
import time
import uuid
from dataclasses import dataclass
from pathlib import Path

from helpers.quiescence import await_quiescent
from helpers.vault import write_note

CONVERGE_BOUND_S = 90
# Catch-up after the push is what fires the drift branch. Prod drift-copied
# within ~20s of the push sweep; give a few manual syncs room to run it.

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

# The plugin codec's re-emit of each shape's frontmatter block (eemeli `yaml`
# via `emitFrontmatter`), measured with the plugin's own codec. Pinned because
# the plugin no longer writes it to disk (Engram-obsidian#683 keeps the user's
# bytes when they mean the same), so a run cannot always observe it. A run on
# a plugin that still rewrites checks the pin against what it wrote. To
# re-measure: docs/context/frontmatter-first-sync-drift-e2e.md section 1.
PLUGIN_EMIT = {
    "wikilink-and-empty": 'up: "[[Home]]"\nstatus: null\n',
    "hashtag-and-flow-list": 'tag: "#project"\ntags:\n  - a\n  - b\n',
    "wikilink-and-quoted-title": 'up: "[[Home]]"\ntitle: Hello\n',
    "colon-and-comment": 'title: "Meeting: kickoff"\n',
    "aliases-flow-wikilinks": 'aliases:\n  - "[[Alpha]]"\n  - "[[Beta]]"\n',
    "tilde-null": "status: null\n",
    "yes-string": "answer: yes\n",
    "obsidian-cssclasses": "cssclasses: null\n",
}


# The shared fence rule (docs/context/frontmatter-fence-rule.md): open at byte
# 0 on a bare `---` line ending LF or CRLF, close on `---` plus optional
# spaces/tabs, then a line ending or end of text.
_FENCED = re.compile(r"\A---\r?\n(.*?\r?\n)??---[ \t]*(?:\r?\n|\Z)", re.S)


def fm_block(text: str) -> str | None:
    """The frontmatter block between the fences, or None if there is none."""
    m = _FENCED.match(text)
    return None if m is None else (m.group(1) or "")


def fm_keys(text: str) -> list[str]:
    """Top-level keys of the frontmatter block in disk order, duplicates kept,
    so a caller can assert a key appears once."""
    block = fm_block(text) or ""
    return re.findall(r"^([^\s:#][^:\r\n]*):", block, re.M)


@dataclass
class FirstSyncResult:
    prefix: str
    written: dict[str, str]
    conflict_copies: list[str]
    rewritten: dict[str, str]
    # The server's rendering of each note (`GET /notes`), i.e. the backend
    # codec's re-emit of the doc the plugin pushed.
    server: dict[str, str]


async def first_sync_shapes(
    vault, cdp, api_sync, shapes: dict[str, str], tag: str
) -> FirstSyncResult:
    prefix = f"{tag}-{uuid.uuid4().hex[:12]}"
    await cdp.set_sync_blocked(True)
    # Record every file the plugin CREATES. A drift-copy cannot be found by
    # scanning disk afterwards: the copy is stamped as synced but never pushed,
    # so the next manifest reconcile reads it as server-deleted and TRASHES it
    # ("Reconcile: server-deleted -> trashed"), within a second.
    await cdp.arm_create_spy()

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
        await asyncio.sleep(1)
    else:
        raise TimeoutError(f"Obsidian indexed only {indexed}/{expected} files")

    await cdp.accept_sync_gate()

    started = time.monotonic()
    landed = 0
    while time.monotonic() < started + CONVERGE_BOUND_S:
        await cdp.set_sync_blocked(False)
        await cdp.trigger_full_sync()
        landed = sum(
            1
            for n in api_sync.get_manifest()["notes"]
            if n["path"].startswith(prefix) and "(conflict" not in n["path"]
        )
        if landed >= expected:
            break
        await asyncio.sleep(2)
    assert landed >= expected, f"sync landed only {landed}/{expected}"

    # The drift branch can fire on a catch-up that follows a backend
    # checkpoint (a CheckpointNote from room-shutdown overflow or a link
    # rewrite, or a room's own checkpoint). The barrier waits for no runnable
    # checkpoint job AND for this device's catch-up cursor to pass the seq it
    # bumps; a job held by a live room is deferred, not
    # waited on.
    await await_quiescent(cdp, api_sync)

    copies = sorted(
        p for p in await cdp.disarm_create_spy() if p.startswith(prefix) and "(conflict" in p
    )
    rewritten = {}
    server = {}
    for rel, original in written.items():
        now = Path(vault, rel).read_text(encoding="utf-8")
        if now != original:
            rewritten[rel] = now
        server[rel] = api_sync.get_note(rel)["content"]
    return FirstSyncResult(prefix, written, copies, rewritten, server)


def three_way_gaps(result: FirstSyncResult, shapes: dict[str, str]) -> list[str]:
    """Shapes whose raw, plugin and backend frontmatter do NOT all differ.

    A drift copy needs all three renderings to disagree; a shape where any two
    agree cannot reach the drift branch, so a pass over it proves nothing.
    """
    gaps = []
    for rel, original in result.written.items():
        name = rel.split("/", 1)[1].removesuffix(".md")
        raw = fm_block(shapes[name])
        plugin = PLUGIN_EMIT[name]
        backend = fm_block(result.server[rel])
        if len({raw, plugin, backend}) != 3:
            gaps.append(f"{name}: raw={raw!r} plugin={plugin!r} backend={backend!r}")
        # Keep the pin honest whenever the plugin shows its re-emit on disk.
        if rel in result.rewritten and fm_block(result.rewritten[rel]) != plugin:
            gaps.append(
                f"{name}: plugin wrote {fm_block(result.rewritten[rel])!r}, pinned {plugin!r}"
            )
    return gaps
