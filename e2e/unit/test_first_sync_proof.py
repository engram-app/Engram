"""The staging first-sync proof's own logic: the prod guard, the corpus, the verdict.

The harness kills a container and posts a PASS/FAIL to a PR, so these pin the
three things that must not silently drift: nothing named prod is ever a target,
the corpus is the same bytes for the same seed, and an OOM or a short count
turns the verdict to FAIL.
"""

from __future__ import annotations

import argparse

import pytest

from load import first_sync_proof as fsp


@pytest.mark.parametrize(
    "name",
    [
        "engram-prod",
        "root@prod-host",
        "engram-saas-PROD",
        "https://api.prod.example/api",
    ],
)
def test_refuses_anything_named_prod(name):
    with pytest.raises(fsp.Refused):
        fsp.refuse_prod("engram-saas", name)


def test_staging_targets_pass_the_guard():
    fsp.refuse_prod(
        fsp.STAGING_HOST, fsp.STAGING_APP, fsp.STAGING_PG, "http://10.0.20.214:8000/api"
    )


def test_corpus_is_deterministic_and_counted(tmp_path):
    a = fsp.generate(tmp_path / "a", notes=30, attachments=4, seed=7)
    b = fsp.generate(tmp_path / "b", notes=30, attachments=4, seed=7)
    c = fsp.generate(tmp_path / "c", notes=30, attachments=4, seed=8)
    assert a == b and a["sha256"] != c["sha256"]
    files = [p for p in (tmp_path / "a").rglob("*") if p.is_file()]
    assert len(files) == 34
    assert sum(1 for p in files if p.suffix == ".md") == 30
    sizes = [p.stat().st_size for p in files if p.suffix != ".md"]
    assert (
        all(1_000 <= s <= 20_000 for s in sizes) and sum(sizes) == a["attachment_bytes"]
    )


def test_refuses_a_non_empty_vault_dir(tmp_path):
    (tmp_path / "stray.md").write_text("x")
    with pytest.raises(SystemExit):
        fsp.generate(tmp_path, notes=1, attachments=0, seed=1)


def _args(**kw):
    base = dict(
        notes=100, attachments=10, seed=1, max_beam_mib=1536, max_tail_rows=5000
    )
    return argparse.Namespace(**(base | kw))


def _run(samples, events=(), logs=None, restarted=None):
    restarted = restarted or {
        "t": 100.0,
        "mode": "kill",
        "rc": 0,
        "progress": 0.5,
        "notes": 50,
    }
    load = {
        "want_notes": 101,
        "want_attachments": 10,
        "attachment_bytes": 2**20,
        "sha256": "ab" * 32,
    }
    return fsp.summarize(
        _args(), "r1", "0.69.0", 42, samples, restarted, list(events), logs or {}, load
    )


GOOD = [
    {
        "t": 50.0,
        "notes": 50,
        "attachments": 5,
        "tail_rows": 300,
        "beam_total": 400 * 2**20,
        "beam_binary": 50 * 2**20,
    },
    {
        "t": 200.0,
        "notes": 101,
        "attachments": 10,
        "tail_rows": 120,
        "beam_total": 500 * 2**20,
        "beam_binary": 80 * 2**20,
    },
]
OUR_KILL = {"status": "die", "time": 101}


def test_clean_run_passes():
    assert "**PASS**" in _run(GOOD, [OUR_KILL]).splitlines()[0]


@pytest.mark.parametrize(
    "samples,events,logs",
    [
        (GOOD, [OUR_KILL, {"status": "oom", "time": 300}], {}),  # an OOM kill
        (
            GOOD,
            [OUR_KILL, {"status": "die", "time": 400}],
            {},
        ),  # a death we did not cause
        ([*GOOD[:1], GOOD[1] | {"notes": 100}], [OUR_KILL], {}),  # one note short
        (
            [*GOOD, {"t": 250.0, "beam_total": 1600 * 2**20}],
            [OUR_KILL],
            {},
        ),  # over the memory bar
        ([*GOOD, {"t": 260.0, "tail_rows": 9000}], [OUR_KILL], {}),  # tail not bounded
        (GOOD, [OUR_KILL], {"db_checkout_over_15s": 2}),  # the 2026-10-29 log signature
    ],
)
def test_each_failure_turns_the_verdict(samples, events, logs):
    assert "**FAIL**" in _run(samples, events, logs).splitlines()[0]


def test_restart_outside_the_window_fails():
    late = {"t": 100.0, "mode": "kill", "rc": 0, "progress": 0.75, "notes": 75}
    assert "**FAIL**" in _run(GOOD, [OUR_KILL], restarted=late).splitlines()[0]


# ---------------------------------------------------------------------------
# Cleanup paths: these run against shared staging, so a crash here strands state.
# ---------------------------------------------------------------------------
class _Proc:
    def __init__(self, rc=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = rc, stdout, stderr


def test_load_host_cleanup_pkill_cannot_match_its_own_shell(tmp_path, monkeypatch):
    """`pkill -f <work>/` matched the ssh shell running it, so `rm -rf` never ran."""
    import re

    work = "/tmp/fsproof.AbC123"
    cmds = []
    monkeypatch.setattr(fsp, "ssh", lambda cmd, **kw: cmds.append(cmd) or _Proc())
    monkeypatch.setattr(fsp.subprocess, "run", lambda *a, **kw: _Proc(rc=1, stdout=b""))
    fsp.fetch_and_clean_load_host("gh-runner", work, tmp_path)
    kill = next(c for c in cmds if "pkill" in c)
    pattern = re.search(r"pkill -f '?([^';\s]+)", kill).group(1)
    load_cmdline = f"python3 e2e/load/first_sync_proof.py load --work {work}/work"
    assert re.search(pattern, load_cmdline), "must still match the load"
    for c in cmds:  # every shell this cleanup runs
        assert not re.search(pattern, c), f"pkill would kill its own shell: {c}"
    assert any(c.strip().endswith(f"rm -rf {work}") for c in cmds)
