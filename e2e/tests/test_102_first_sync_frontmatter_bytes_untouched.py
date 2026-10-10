"""Test 102: syncing a note must not rewrite frontmatter the user never edited.

engram-app/Engram#1928, the second half. The CRDT stores frontmatter as
values and re-emits YAML from them, with a different emitter on each side
(plugin eemeli `yaml`, backend Ymlr). So an untouched note comes back with
quotes changed, `key:` turned into `key: null`, long lines folded, comments
dropped, and a quoted date string turned into a real date. Obsidian users
see their files change for no reason.

Relay keeps frontmatter as verbatim text and never re-emits on a clean sync.
This test holds Engram to the same bar: bytes in == bytes out.
"""

from __future__ import annotations

import pytest

from helpers.frontmatter_first_sync import DRIFTING_SHAPES, first_sync_shapes

# Shapes both emitters rewrite IDENTICALLY: no conflict, but the user's file
# still changes on disk.
REFORMAT_SHAPES = {
    "quoted-plain": '---\ntitle: "Hello"\n---\n',
    "flow-list": "---\ntags: [a, b]\n---\n",
    "comment": "---\ntitle: Hello # keep me\n---\n",
    "quoted-date-string": '---\ndue: "2026-10-10"\n---\n',
}


@pytest.mark.asyncio
async def test_first_sync_leaves_frontmatter_bytes_untouched(vault_a, cdp_a, api_sync):
    result = await first_sync_shapes(
        vault_a, cdp_a, api_sync, {**DRIFTING_SHAPES, **REFORMAT_SHAPES}, "FmBytes"
    )
    diffs = "\n".join(
        f"  {rel}:\n    wrote: {result.written[rel]!r}\n    now:   {now!r}"
        for rel, now in sorted(result.rewritten.items())
    )
    assert result.rewritten == {}, (
        f"sync rewrote {len(result.rewritten)} untouched notes on disk:\n{diffs}"
    )
