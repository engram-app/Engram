"""Test 88: Rename link-rewrite (#648/#1240/#1266) — cross-client E2E proof.

The shipped feature: renaming a note/folder via REST/MCP (or web CRDT,
client_type-gated) rewrites every referring note's [[wikilinks]] server-side
as Y-updates; plugin-origin (Obsidian) renames are NOT rewritten by the
server — Obsidian's own "update internal links" owns those (the
one-rewriter invariant). Unit/worker/channel layers are pinned in ExUnit;
this file is the missing cross-client proof through real Obsidian instances:

  1. REST rename → referrer's [[Target]] / [[Target|alias]] / [[Target#H]]
     converge to [[Fresh]] forms in BOTH vaults; target row survives (same id).
  2. Obsidian-origin rename → Obsidian rewrites locally, server must NOT
     rewrite again (double-rewrite would duplicate the new name in the text);
     server content converges to exactly the plugin's local content.
  3. REST folder rename → qualified [[dir/Inner]] gets the new prefix, bare
     [[Inner]] (basename unchanged) is left verbatim, both instances.

DELIBERATELY NOT COVERED: the +60s delayed sweep (#1266) that catches edges
indexed late. Racing "rename before the edge lands, then wait >60s for the
sweep" is timing-hostile in CI (the edge usually lands in <1s, making the
pre-sweep window unforceable from out here) and the sweep is already pinned
at the worker layer. Instead every scenario WAITS for the note_links edge
via GET /notes/by-id/:id/backlinks before renaming, so the immediate rewrite
path is what's under test — deterministically.

Rerun-safety: unique per-run basenames (uuid suffix) per the delivery-flake
playbook §5 — session-scoped vaults + the hash-equal broadcast-skip make
fixed paths poison rerun attempts.
"""

import asyncio
import json
import logging
import re
import time
import uuid

import pytest

from helpers.latency import DELIVERY_TIMEOUT
from helpers.log_oracle import wait_for_delivery
from helpers.vault import wait_for_content, wait_for_exact_content, write_note

logger = logging.getLogger(__name__)


def _wait_for_backlink(
    api, note_id: str, source_path: str, timeout: float = DELIVERY_TIMEOUT
) -> None:
    """Poll until a note_links edge from ``source_path`` targets ``note_id``.

    The edge is written by the async embed/index pipeline; the rewriter walks
    these edges, so renaming before the edge exists would exercise only the
    +60s sweep (out of scope here — see module docstring).
    """
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        edges = api.get_backlinks(note_id)
        if any(e.get("source_path") == source_path for e in edges):
            logger.info("backlink edge %s -> %s indexed", source_path, note_id)
            return
        time.sleep(0.5)
    raise TimeoutError(
        f"note_links edge {source_path} -> {note_id} not indexed within "
        f"{timeout}s (embed pipeline stalled? backlinks={api.get_backlinks(note_id)})"
    )


def _wait_server_content_equals(
    api, path: str, expected: str, timeout: float = DELIVERY_TIMEOUT
) -> None:
    """Poll until the SERVER's content for ``path`` equals ``expected`` exactly."""
    last = None
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        note = api.get_note(path)
        if note is not None:
            last = note.get("content", "")
            if last == expected:
                return
        time.sleep(0.5)
    raise TimeoutError(
        f"server content for {path} never matched expected within {timeout}s\n"
        f"--- expected ---\n{expected!r}\n--- last seen ---\n{last!r}"
    )


async def _wait_obsidian_link_indexed(
    cdp, source_path: str, target_path: str, timeout: float = 60
) -> None:
    """Poll Obsidian's metadataCache until it resolved source→target.

    Obsidian only auto-updates links it has indexed; renaming before the
    cache catches up silently skips the local rewrite and the test would
    measure nothing.
    """
    js = (
        f"(() => (app.metadataCache.resolvedLinks[{json.dumps(source_path)}] "
        f"|| {{}})[{json.dumps(target_path)}] || 0)()"
    )
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if await cdp.evaluate(js):
            logger.info("obsidian metadataCache resolved %s -> %s", source_path, target_path)
            return
        await asyncio.sleep(0.5)
    raise TimeoutError(
        f"Obsidian metadataCache never resolved {source_path} -> {target_path} "
        f"within {timeout}s"
    )


@pytest.mark.asyncio
async def test_rest_rename_rewrites_links_cross_client(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """REST rename of a linked note rewrites the referrer in BOTH vaults."""
    suffix = uuid.uuid4().hex[:12]
    old_base = f"Target88-{suffix}"
    new_base = f"Fresh88-{suffix}"
    target = f"E2E/{old_base}.md"
    fresh = f"E2E/{new_base}.md"
    referrer = f"E2E/Referrer88-{suffix}.md"

    target_body = "# H\n\nTarget body 88."
    referrer_body = (
        f"# Referrer\n\n"
        f"Plain [[{old_base}]] link.\n"
        f"Alias [[{old_base}|alias]] link.\n"
        f"Heading [[{old_base}#H]] link.\n"
    )

    # A authors both notes; server + B must hold them before the rename.
    write_note(vault_a, target, target_body)
    write_note(vault_a, referrer, referrer_body)
    target_note = api_sync.wait_for_note(target)
    api_sync.wait_for_note(referrer)
    wait_for_delivery(vault_b, target, api_sync)
    wait_for_delivery(vault_b, referrer, api_sync)

    # Settle gate: the rewriter walks note_links edges — wait for the async
    # index to have written the referrer -> target edge.
    _wait_for_backlink(api_sync, target_note["id"], referrer)

    logger.info("renaming %s -> %s via REST", target, fresh)
    status = api_sync.rename_note(target, fresh)
    assert status == 200, f"REST rename should succeed, got {status}"

    # All three link forms converge in BOTH vaults: bare stays bare, |alias
    # and #anchor segments are preserved verbatim (rewriter policy).
    expected = referrer_body.replace(old_base, new_base)
    a_content = wait_for_exact_content(vault_a, referrer, expected)
    b_content = wait_for_exact_content(vault_b, referrer, expected)
    assert old_base not in a_content and old_base not in b_content

    # Server-side referrer content converged too (the Y-update was persisted,
    # not just broadcast).
    _wait_server_content_equals(api_sync, referrer, expected)

    # Target survived the rename: same row id, same content, new path only.
    fresh_note = api_sync.wait_for_note(fresh)
    assert fresh_note["id"] == target_note["id"], "rename must keep the note's identity"
    assert "Target body 88." in fresh_note.get("content", "")
    api_sync.wait_for_note_gone(target)
    wait_for_delivery(vault_b, fresh, api_sync)


@pytest.mark.asyncio
async def test_obsidian_rename_no_double_rewrite(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """Obsidian-origin rename: Obsidian rewrites locally, server must NOT.

    The one-rewriter invariant (#648 Phase 2): plugin-origin renames carry
    client_type=obsidian and the server skips its rewrite. The double-rewrite
    failure mode would splice the new name into text that already carries it —
    so the new basename must appear EXACTLY once, and the server's stored
    content must equal the plugin's local file (no server-authored second
    edit fighting the plugin's).
    """
    suffix = uuid.uuid4().hex[:12]
    old_base = f"Orig88-{suffix}"
    new_base = f"Moved88-{suffix}"
    orig = f"E2E/{old_base}.md"
    moved = f"E2E/{new_base}.md"
    referrer = f"E2E/Referrer88b-{suffix}.md"
    referrer_body = f"# Ref\n\nOne link: [[{old_base}]] only.\n"

    write_note(vault_a, orig, "# Orig\n\nBody 88b.")
    write_note(vault_a, referrer, referrer_body)
    orig_note = api_sync.wait_for_note(orig)
    api_sync.wait_for_note(referrer)
    wait_for_delivery(vault_b, orig, api_sync)
    wait_for_delivery(vault_b, referrer, api_sync)

    # Server edge must exist BEFORE the rename: a buggy server-side rewrite
    # can only fire if it has the edge to walk — without this wait a
    # regression could pass vacuously.
    _wait_for_backlink(api_sync, orig_note["id"], referrer)
    # Obsidian must have indexed the link, or its auto-update skips the file.
    await _wait_obsidian_link_indexed(cdp_a, referrer, orig)

    # Deterministic link auto-update: don't rely on the vault-config default.
    await cdp_a.evaluate("app.vault.setConfig('alwaysUpdateLinks', true)")

    # Rename through fileManager (link-aware). cdp.rename_file uses
    # app.vault.rename, which deliberately BYPASSES link auto-update — the
    # wrong surface for this scenario.
    logger.info("renaming %s -> %s via Obsidian fileManager", orig, moved)
    await cdp_a.evaluate(
        f"""
        (async () => {{
            const f = app.vault.getAbstractFileByPath({json.dumps(orig)});
            if (!f) throw new Error('file not found: ' + {json.dumps(orig)});
            await app.fileManager.renameFile(f, {json.dumps(moved)});
            return 'renamed';
        }})()
        """,
        await_promise=True,
    )

    api_sync.wait_for_note(moved)

    # Obsidian rewrote A's referrer locally; the edit syncs to B. (A's final
    # text is re-read from disk below after the server-equality wait.)
    wait_for_content(vault_a, referrer, new_base)
    b_content = wait_for_content(vault_b, referrer, new_base)

    # Server content equals the plugin's local content — the server accepted
    # the plugin's rewrite verbatim and did not author a second one on top.
    a_final = (vault_a / referrer).read_text(encoding="utf-8")
    _wait_server_content_equals(api_sync, referrer, a_final)

    # Exactly-once per link: a double rewrite duplicates the new name.
    for who, content in (("A", a_final), ("B", b_content)):
        count = len(re.findall(re.escape(new_base), content))
        assert count == 1, (
            f"{who}'s referrer should carry {new_base!r} exactly once "
            f"(double-rewrite fingerprint), got {count}: {content!r}"
        )
        assert old_base not in content, f"{who} still references {old_base!r}: {content!r}"


@pytest.mark.asyncio
async def test_folder_rename_rewrites_qualified_links_only(
    vault_a, vault_b, cdp_a, cdp_b, api_sync
):
    """REST folder rename: qualified links get the new prefix, bare links don't.

    A folder rename is N note renames with the basename unchanged, so the
    rewriter's form rule requalifies [[old-dir/Inner]] -> [[new-dir/Inner]]
    and plans NO edit for bare [[Inner]] (replacement == occurrence text).
    """
    suffix = uuid.uuid4().hex[:12]
    old_folder = f"E2E/LinkDir88-{suffix}"
    new_folder = f"E2E/LinkTgt88-{suffix}"
    inner_base = f"Inner88-{suffix}"
    inner = f"{old_folder}/{inner_base}.md"
    outside = f"E2E/Outside88-{suffix}.md"

    outside_body = (
        f"Qualified [[{old_folder}/{inner_base}]] link.\n"
        f"Bare [[{inner_base}]] link.\n"
    )

    write_note(vault_a, inner, "# Inner\n\nInner body 88.")
    write_note(vault_a, outside, outside_body)
    inner_note = api_sync.wait_for_note(inner)
    api_sync.wait_for_note(outside)
    wait_for_delivery(vault_b, inner, api_sync)
    wait_for_delivery(vault_b, outside, api_sync)

    # Both edges (qualified + bare) target the inner note; one indexed
    # backlink from `outside` proves the walk will visit it.
    _wait_for_backlink(api_sync, inner_note["id"], outside)

    logger.info("renaming folder %s -> %s via REST", old_folder, new_folder)
    status = api_sync.rename_folder(old_folder, new_folder)
    assert status == 200, f"folder rename should succeed, got {status}"
    api_sync.wait_for_note(f"{new_folder}/{inner_base}.md")

    # Qualified link requalified; bare link byte-identical (exact match
    # asserts both at once).
    expected = (
        f"Qualified [[{new_folder}/{inner_base}]] link.\n"
        f"Bare [[{inner_base}]] link.\n"
    )
    wait_for_exact_content(vault_a, outside, expected)
    wait_for_exact_content(vault_b, outside, expected)
