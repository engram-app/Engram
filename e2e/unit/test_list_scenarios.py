"""Unit tests for scripts/list_scenarios.py — no stack needed."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

SCRIPT = Path(__file__).resolve().parent.parent / "scripts" / "list_scenarios.py"


def _spec(title, tags, annotations):
    return {
        "title": title,
        "file": "mcp-first-journey.spec.ts",
        "tags": tags,
        "tests": [{"annotations": annotations}],
    }


def _pw(*specs):
    # Playwright nests suites (file > describe); specs live at any depth.
    return {
        "suites": [{"title": "f", "suites": [{"title": "d", "specs": list(specs)}]}]
    }


def _run(tmp_path, pw, collect=None):
    pw_file = tmp_path / "pw.json"
    pw_file.write_text(json.dumps(pw))
    py_file = tmp_path / "py.json"
    py_file.write_text(json.dumps(collect or []))
    return subprocess.run(
        [
            sys.executable,
            str(SCRIPT),
            "--playwright-json",
            str(pw_file),
            "--pytest-collect",
            str(py_file),
        ],
        capture_output=True,
        text=True,
    )


CANARY = [
    {"type": "cadence", "description": "hourly"},
    {"type": "targets", "description": "ci,staging"},
]


def test_playwright_canary_scenario_listed(tmp_path):
    r = _run(tmp_path, _pw(_spec("journey", ["@canary"], CANARY)))
    assert r.returncode == 0, r.stderr
    assert json.loads(r.stdout) == [
        {
            "name": "journey",
            "runner": "playwright",
            "file": "mcp-first-journey.spec.ts",
            "cadence": "hourly",
            "targets": ["ci", "staging"],
            "tags": ["@canary"],
        }
    ]


def test_untagged_tests_ignored(tmp_path):
    r = _run(tmp_path, _pw(_spec("plain", [], [])))
    assert r.returncode == 0
    assert json.loads(r.stdout) == []


def test_missing_cadence_fails_naming_the_test(tmp_path):
    r = _run(tmp_path, _pw(_spec("no cadence here", ["@canary"], CANARY[1:])))
    assert r.returncode == 1
    assert "no cadence here" in r.stderr


def test_unknown_target_fails(tmp_path):
    ann = [CANARY[0], {"type": "targets", "description": "ci,mars"}]
    r = _run(tmp_path, _pw(_spec("bad target", ["@canary"], ann)))
    assert r.returncode == 1
    assert "bad target" in r.stderr and "mars" in r.stderr


def test_pytest_collect_entries_merged(tmp_path):
    collect = [
        {
            "nodeid": "tests/test_x.py::test_y",
            "cadence": "daily",
            "targets": ["staging-limits"],
        }
    ]
    r = _run(tmp_path, _pw(_spec("journey", ["@canary"], CANARY)), collect)
    assert r.returncode == 0, r.stderr
    out = json.loads(r.stdout)
    assert [e["runner"] for e in out] == ["playwright", "pytest"]
    assert out[1] == {
        "name": "tests/test_x.py::test_y",
        "runner": "pytest",
        "file": "tests/test_x.py",
        "cadence": "daily",
        "targets": ["staging-limits"],
        "tags": ["canary"],
    }


def test_timed_step_records_ok_and_failure():
    import pytest

    from helpers.scenario import bind_steps, timed_step, unbind_steps

    props: list = []
    steps = bind_steps(props)
    try:
        with timed_step("a"):
            pass
        with pytest.raises(ValueError):
            with timed_step("b"):
                raise ValueError("boom")
    finally:
        unbind_steps()
    assert props == [("steps", steps)]
    assert [(s["step"], s["ok"]) for s in steps] == [("a", True), ("b", False)]
    assert all(s["seconds"] >= 0 for s in steps)
