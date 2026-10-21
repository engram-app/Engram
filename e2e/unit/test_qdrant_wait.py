"""wait_for_qdrant_indexed follows the EmbedNote job, not a fixed clock."""

import pytest

from helpers import crypto_probe as cp

VID = "00000000-0000-0000-0000-000000000001"
HMAC = "abc123=="


@pytest.fixture
def clock(monkeypatch):
    t = {"now": 0.0}
    monkeypatch.setattr(cp.time, "monotonic", lambda: t["now"])
    monkeypatch.setattr(cp.time, "sleep", lambda s: t.__setitem__("now", t["now"] + s))
    return t


def script(monkeypatch, clock, point_at=None, states=None, default=(None, "")):
    """point appears once the fake clock reaches `point_at`; job state is states[poll]."""
    calls = {"n": 0}
    monkeypatch.setattr(
        cp, "_qdrant_has_point",
        lambda v, h: point_at is not None and clock["now"] >= point_at,
    )

    def state(v, h):
        i = calls["n"]
        calls["n"] += 1
        return states[i] if states and i < len(states) else (states[-1] if states else default)

    monkeypatch.setattr(cp, "_embed_job_state", state)
    return calls


def test_returns_when_point_appears(monkeypatch, clock):
    script(monkeypatch, clock, point_at=0)
    cp.wait_for_qdrant_indexed(VID, HMAC)


def test_discarded_job_fails_fast_with_errors(monkeypatch, clock):
    script(monkeypatch, clock, states=[("discarded", "boom: ollama 500")])
    with pytest.raises(RuntimeError) as e:
        cp.wait_for_qdrant_indexed(VID, HMAC)
    assert "discarded" in str(e.value) and "boom: ollama 500" in str(e.value)
    assert clock["now"] <= 1


def test_cancelled_job_fails_fast(monkeypatch, clock):
    script(monkeypatch, clock, states=[("cancelled", "")])
    with pytest.raises(RuntimeError, match="cancelled"):
        cp.wait_for_qdrant_indexed(VID, HMAC)


def test_alive_job_outlives_timeout(monkeypatch, clock):
    script(monkeypatch, clock, point_at=95, states=[("executing", "")])
    cp.wait_for_qdrant_indexed(VID, HMAC, timeout=30)
    assert clock["now"] >= 95


def test_hard_cap_bounds_an_alive_job(monkeypatch, clock):
    script(monkeypatch, clock, states=[("retryable", "x")])
    with pytest.raises(TimeoutError, match="retryable"):
        cp.wait_for_qdrant_indexed(VID, HMAC, timeout=30, hard_cap=100)
    assert 100 <= clock["now"] <= 102


def test_default_hard_cap_fits_under_pytest_timeout(monkeypatch, clock):
    # pytest.ini kills a test at 180s; the named TimeoutError must fire first.
    script(monkeypatch, clock, states=[("executing", "")])
    with pytest.raises(TimeoutError, match="executing"):
        cp.wait_for_qdrant_indexed(VID, HMAC, timeout=30)
    assert clock["now"] <= 125


def test_completed_without_point_times_out(monkeypatch, clock):
    script(monkeypatch, clock, states=[("completed", "")])
    with pytest.raises(TimeoutError, match="completed"):
        cp.wait_for_qdrant_indexed(VID, HMAC, timeout=30)
    assert 30 <= clock["now"] <= 32


def test_no_job_times_out(monkeypatch, clock):
    script(monkeypatch, clock)
    with pytest.raises(TimeoutError):
        cp.wait_for_qdrant_indexed(VID, HMAC, timeout=10)


def test_embed_job_state_rejects_unsafe_input():
    with pytest.raises(ValueError):
        cp._embed_job_state("x'; drop table notes;--", HMAC)
    with pytest.raises(ValueError):
        cp._embed_job_state(VID, "a'b")
