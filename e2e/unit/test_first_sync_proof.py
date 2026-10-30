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


KEY = "engram_" + "k" * 32


def test_fetched_load_output_is_redacted_and_load_stopped_first(tmp_path, monkeypatch):
    """A killed or crashed load leaves the raw key in its log: never copy it home."""
    order = []

    def fake_ssh(cmd, **kw):
        order.append("pkill" if "pkill" in cmd else cmd.split()[0])
        return _Proc()

    def fake_run(argv, **kw):
        if argv[0] == "ssh":  # the remote `tar -c out`
            order.append("fetch")
            return _Proc(stdout=b"tar")
        d = tmp_path / "load" / "out"  # the local `tar -x`
        d.mkdir(parents=True)
        (d / "first_sync.log").write_text(f"ws?token={KEY}&vsn=2 failed\n")
        (d / "first_sync.jsonl").write_text(f'{{"err": "Bearer {KEY}"}}\n')
        return _Proc()

    monkeypatch.setattr(fsp, "ssh", fake_ssh)
    monkeypatch.setattr(fsp.subprocess, "run", fake_run)
    fsp.fetch_and_clean_load_host("gh-runner", "/tmp/fsproof.x", tmp_path)
    for f in (tmp_path / "load" / "out").iterdir():
        assert KEY not in f.read_text(), f.name
    assert order.index("pkill") < order.index("fetch"), order


def test_signal_exit_runs_the_load_log_redaction(monkeypatch):
    """SIGTERM ends the load through os._exit, which skips every finally."""
    from load import sim

    handlers, calls = {}, []
    monkeypatch.setattr(sim.signal, "signal", lambda s, h: handlers.__setitem__(s, h))
    monkeypatch.setattr(sim.os, "_exit", lambda code: calls.append(("exit", code)))
    sim.install_signal_handlers(on_exit=lambda: calls.append("redact"))
    handlers[sim.signal.SIGTERM](sim.signal.SIGTERM, None)
    assert calls == ["redact", ("exit", 128 + sim.signal.SIGTERM)]


def test_qdrant_guard_counts_only_the_run_users_points(monkeypatch):
    """The collection is shared with CI: a global count false-aborts and hides leaks."""
    import sys
    import types

    cond = {"key": "u", "match": {"value": "0f3a"}}
    exprs, posts = [], []
    monkeypatch.setattr(
        fsp,
        "rpc",
        lambda expr, **kw: (
            exprs.append(expr) or f"qdrant|obsidian_notes_v3|{fsp.json.dumps(cond)}\n"
        ),
    )

    class Resp:
        def raise_for_status(self):
            pass

        def json(self):
            return {"result": {"count": 3}}

    fake = types.SimpleNamespace(
        post=lambda url, json, timeout: posts.append((url, json)) or Resp()
    )
    monkeypatch.setitem(sys.modules, "requests", fake)
    scope = fsp.qdrant_scope("0f3a-uuid")
    assert 'match_filter(:user, "0f3a-uuid")' in exprs[0]  # the indexed tenant key
    assert fsp.qdrant_points(scope) == 3
    url, body = posts[0]
    assert url.endswith("/collections/obsidian_notes_v3/points/count")
    assert body == {"filter": {"must": [cond]}, "exact": True}


def _cleanup_env(tmp_path, monkeypatch, fail=()):
    """Mock every staging/load-host call cleanup makes; names in `fail` raise."""
    calls = []

    def step(name, ret=None):
        def fn(*args, **kw):
            calls.append((name, *args[:1]) if name == "pause" else name)
            if name in fail:
                raise RuntimeError(
                    f"{name} boom 40P01" if name == "delete" else f"{name} boom"
                )
            return ret

        return fn

    def fake_ssh(cmd, **kw):
        if "docker events" in cmd and "events" in fail:
            raise fsp.subprocess.TimeoutExpired(cmd, 60)
        return _Proc(stdout="0\n")

    monkeypatch.setattr(fsp, "ssh", fake_ssh)
    monkeypatch.setattr(fsp, "fetch_and_clean_load_host", step("load_host"))
    monkeypatch.setattr(fsp, "start_container", step("start"))
    monkeypatch.setattr(fsp, "wait_rpc", step("wait_rpc"))
    monkeypatch.setattr(fsp, "pause_qdrant_queues", step("pause"))
    monkeypatch.setattr(fsp, "cancel_user_jobs", step("cancel", "0"))
    monkeypatch.setattr(fsp, "delete_user", step("delete", ":ok"))
    a = argparse.Namespace(load_host="gh-runner")
    run = lambda: fsp.cleanup(  # noqa: E731
        a, tmp_path, "2026-10-30T00:00:00Z", "/tmp/fsproof.x", "uid", "kid", True
    )
    return calls, run


def test_cleanup_survives_every_failing_step_and_resumes_queues_last(
    tmp_path, monkeypatch
):
    """One raising step used to skip the rest: user left behind, staging queues paused."""
    calls, run = _cleanup_env(
        tmp_path, monkeypatch, fail={"events", "load_host", "cancel"}
    )
    _, _, errors = run()
    assert calls == [
        "load_host",
        "start",
        "wait_rpc",
        ("pause", True),
        "cancel",
        "delete",
        ("pause", False),
    ]
    assert [e.split(":")[0] for e in errors] == [
        "docker events",
        "load host",
        "cancel jobs",
    ]


def test_cleanup_resumes_queues_even_when_staging_rpc_never_answers(
    tmp_path, monkeypatch
):
    calls, run = _cleanup_env(tmp_path, monkeypatch, fail={"wait_rpc"})
    _, _, errors = run()
    assert calls[-1] == ("pause", False)
    assert "delete" not in calls and errors


def test_delete_user_retries_a_deadlock_but_not_a_real_refusal(monkeypatch):
    """Engram#2339: delete_account can deadlock (40P01) with the folder backfill."""
    monkeypatch.setattr(fsp.time, "sleep", lambda s: None)
    answers = iter(
        [
            "del|{:error, :pg_failed}\n",
            RuntimeError("** (Postgrex.Error) ERROR 40P01 (deadlock_detected)"),
            "del|:ok\n",
        ]
    )

    def fake_rpc(expr, **kw):
        x = next(answers)
        if isinstance(x, Exception):
            raise x
        return x

    monkeypatch.setattr(fsp, "rpc", fake_rpc)
    assert fsp.delete_user("uid", "kid") == ":ok"

    monkeypatch.setattr(fsp, "rpc", lambda expr, **kw: "del|{:error, :last_admin}\n")
    with pytest.raises(RuntimeError, match="last_admin"):
        fsp.delete_user("uid", "kid")


def test_cleanup_with_staging_down_still_cleans_the_rest_and_says_so(
    tmp_path, monkeypatch, capsys
):
    """A failed `docker start` left staging down; cleanup then burned 300 s on rpc."""
    calls, run = _cleanup_env(tmp_path, monkeypatch, fail={"start"})
    _, _, errors = run()
    assert calls == ["load_host", "start"]  # no rpc step against a dead container
    assert errors and "OPERATOR ACTION" in capsys.readouterr().out


def test_restart_retries_a_failed_start_and_never_raises(monkeypatch):
    monkeypatch.setattr(fsp.time, "sleep", lambda s: None)
    cmds = []
    starts = iter([_Proc(rc=1, stderr="busy"), _Proc(rc=1, stderr="busy"), _Proc()])

    def fake_ssh(cmd, **kw):
        cmds.append(cmd)
        return next(starts) if cmd.startswith("docker start") else _Proc()

    monkeypatch.setattr(fsp, "ssh", fake_ssh)
    r = fsp.restart("kill")
    assert r["rc"] == 0
    assert sum(c.startswith("docker start") for c in cmds) == 3

    def hang(cmd, **kw):
        raise fsp.subprocess.TimeoutExpired(cmd, 120)

    monkeypatch.setattr(fsp, "ssh", hang)
    r = fsp.restart("kill")  # a hung ssh is a failed restart, not a crash
    assert r["rc"] != 0
