"""Unit tests for the Qdrant CI-collection reaper — no Qdrant/GitHub needed.

Locks the two safety invariants: never touch a non-CI (real) collection, and
never reap a collection whose run is still active.
"""

from __future__ import annotations

import importlib.util
import os

# The reaper lives in e2e/scripts/ (not a package); load it by path.
_spec = importlib.util.spec_from_file_location(
    "cleanup_qdrant_collections",
    os.path.join(os.path.dirname(__file__), "..", "scripts", "cleanup_qdrant_collections.py"),
)
reaper = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(reaper)


def test_is_ci_collection_only_matches_ci_prefixes():
    assert reaper.is_ci_collection("ci_test_123_obsidian")
    assert reaper.is_ci_collection("ci_crdt_123")
    assert reaper.is_ci_collection("ci_test_notes")
    # Real vaults must NEVER match.
    assert not reaper.is_ci_collection("obsidian_notes")
    assert not reaper.is_ci_collection("obsidian_notes_selfhost")
    assert not reaper.is_ci_collection("engram_selfhost_fresh_open-claw")


def test_run_id_extraction():
    assert reaper.run_id_of("ci_test_29677548899_obsidian") == "29677548899"
    assert reaper.run_id_of("ci_crdt_29677548899") == "29677548899"
    assert reaper.run_id_of("ci_test_notes") is None  # compose default, no id


def test_orphans_exclude_active_runs_and_real_collections():
    names = [
        "ci_test_111_obsidian",   # active → keep
        "ci_crdt_111",            # active → keep
        "ci_test_222_obsidian",   # inactive → reap
        "ci_crdt_333",            # inactive → reap
        "ci_test_notes",          # no run id → reap
        "obsidian_notes",         # real → never
        "obsidian_notes_selfhost",  # real → never
    ]
    orphans = reaper.orphaned_ci_collections(names, active_run_ids={"111"})

    assert set(orphans) == {"ci_test_222_obsidian", "ci_crdt_333", "ci_test_notes"}
    # The active run's collections and all real vaults are preserved.
    assert "ci_test_111_obsidian" not in orphans
    assert "ci_crdt_111" not in orphans
    assert "obsidian_notes" not in orphans
    assert "obsidian_notes_selfhost" not in orphans


def test_empty_active_set_still_never_touches_real_collections():
    # Even with no active runs (worst case), non-CI collections are untouched.
    names = ["ci_test_1_obsidian", "obsidian_notes", "obsidian_notes_selfhost"]
    orphans = reaper.orphaned_ci_collections(names, active_run_ids=set())
    assert orphans == ["ci_test_1_obsidian"]
