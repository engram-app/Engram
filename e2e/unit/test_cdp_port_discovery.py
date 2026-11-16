"""CDP port discovery: Obsidian picks its own port, we read it back.

Run 39520960336 (e2e-clerk) lost test_82 to a pre-picked CDP port that a
foreign HTTP server took before Obsidian launched; the harness then polled its
`404` for 60s. These lock the two guards: parse DevToolsActivePort, and reject
a /json/version answer that is not Chromium.
"""

from __future__ import annotations

import pytest
import requests

from helpers.obsidian import (
    CdpPortHijacked,
    check_devtools_version,
    read_devtools_active_port,
)


def _resp(status: int, body: bytes) -> requests.Response:
    r = requests.Response()
    r.status_code = status
    r._content = body
    return r


def test_reads_port_from_first_line(tmp_path):
    (tmp_path / "DevToolsActivePort").write_text("58175\n/devtools/browser/abc-123")
    assert read_devtools_active_port(tmp_path) == 58175


def test_missing_file_means_not_ready(tmp_path):
    assert read_devtools_active_port(tmp_path) is None


@pytest.mark.parametrize("partial", ["", "\n", "581x"])
def test_partial_write_means_not_ready(tmp_path, partial):
    (tmp_path / "DevToolsActivePort").write_text(partial)
    assert read_devtools_active_port(tmp_path) is None


def test_accepts_chromium_version():
    body = b'{"Browser": "Chrome/132.0.6834.210", "webSocketDebuggerUrl": "ws://x"}'
    check_devtools_version(9250, _resp(200, body))


def test_rejects_foreign_404():
    # The real failure: 404 with a 16678-byte HTML page.
    with pytest.raises(CdpPortHijacked, match="port 58175 is held by another process"):
        check_devtools_version(58175, _resp(404, b"<html>" + b"x" * 16672))


@pytest.mark.parametrize("body", [b"<html>ok</html>", b"[]", b'{"status": "ok"}'])
def test_rejects_200_that_is_not_chromium(body):
    with pytest.raises(CdpPortHijacked):
        check_devtools_version(9250, _resp(200, body))


def test_a_slow_first_answer_is_polled_again(tmp_path, monkeypatch):
    # PR 2606's e2e-clerk run lost test_82's setup: Chromium accepted the
    # socket but answered /json/version after the 2 s read timeout, and
    # `ReadTimeout` is not a `ConnectionError`, so the first slow reply
    # raised instead of polling to the deadline.
    import helpers.obsidian as obsidian

    (tmp_path / "DevToolsActivePort").write_text("58175\n/devtools/browser/abc")
    answers = iter(
        [
            requests.ReadTimeout("slow boot"),
            _resp(200, b'{"Browser": "Chrome/132.0.6834.210", "webSocketDebuggerUrl": "ws://x"}'),
        ]
    )

    def fake_get(*_args, **_kwargs):
        answer = next(answers)
        if isinstance(answer, Exception):
            raise answer
        return answer

    monkeypatch.setattr(obsidian.requests, "get", fake_get)
    monkeypatch.setattr(obsidian.time, "sleep", lambda _s: None)
    monkeypatch.setattr(obsidian, "CdpClient", lambda port: ("cdp", port))

    inst = obsidian.ObsidianInstance.__new__(obsidian.ObsidianInstance)
    inst.name = "a"
    inst.config_dir = tmp_path
    inst.cdp = None

    inst._wait_for_cdp(timeout=5)

    assert inst.cdp_port == 58175
    assert inst.cdp == ("cdp", 58175)
