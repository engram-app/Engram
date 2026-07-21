"""Unit check for the conftest infra circuit breaker. Needs no stack.

Drives the pytest_runtest_makereport hookwrapper directly with fake
report/item objects, so the abort logic is exercised without killing a
real run. Named test_00_* so it runs (and fails loudly) before anything
that depends on the breaker's behavior.
"""

import conftest as harness


class _Rep:
    def __init__(self, when="call", passed=False, failed=True, longrepr=""):
        self.when = when
        self.passed = passed
        self.failed = failed
        self.longrepr = longrepr


class _Outcome:
    def __init__(self, rep):
        self._rep = rep

    def get_result(self):
        return self._rep


class _Session:
    shouldstop = False


class _Item:
    def __init__(self, session):
        self.session = session
        self.nodeid = "fake.py::test_fake"


class _Call:
    excinfo = None


def _drive(item, rep):
    gen = harness.pytest_runtest_makereport(item, _Call())
    next(gen)
    try:
        gen.send(_Outcome(rep))
    except StopIteration:
        pass


_CONN_REP = _Rep(longrepr="ConnectionError: [Errno 111] Connection refused")


def _reset(monkeypatch, alive):
    harness._consecutive_conn_failures = 0
    monkeypatch.setattr(harness, "_backend_alive", lambda: alive)


def test_dead_backend_aborts_immediately(monkeypatch):
    _reset(monkeypatch, alive=False)
    item = _Item(_Session())
    _drive(item, _CONN_REP)
    assert item.session.shouldstop
    assert "backend" in item.session.shouldstop


def test_healthy_backend_needs_consecutive_failures(monkeypatch):
    _reset(monkeypatch, alive=True)
    item = _Item(_Session())
    for _ in range(harness._OBSIDIAN_DEAD_THRESHOLD - 1):
        _drive(item, _CONN_REP)
    assert not item.session.shouldstop
    _drive(item, _CONN_REP)
    assert item.session.shouldstop
    assert "Obsidian" in item.session.shouldstop


def test_pass_and_unrelated_failure_reset_the_counter(monkeypatch):
    _reset(monkeypatch, alive=True)
    item = _Item(_Session())
    _drive(item, _CONN_REP)
    _drive(item, _Rep(passed=True, failed=False))
    _drive(item, _CONN_REP)
    _drive(item, _Rep(longrepr="AssertionError: something else"))
    _drive(item, _CONN_REP)
    assert harness._consecutive_conn_failures == 1
    assert not item.session.shouldstop
