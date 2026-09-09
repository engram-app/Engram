"""Test 18: CDP target selection survives Obsidian's multi-window settings.

Pure unit test — no Obsidian, no stack calls. It exists because the failure it
guards is invisible in the worst way.

Obsidian 1.13 moved Settings into a separate Electron window. The CDP client
took `pages[0]` with no filter, and the settings window sorts ahead of the app
window, so from the first `app.setting.open()` onward every `evaluate` landed
in a window with no `app` global. Fifteen tests went red with
`ReferenceError: app is not defined`, which reads like a crashed renderer and
was nothing of the kind — an environment change, delivered by an
Obsidian-update cron, presenting as a product failure.

The guarantees pinned here: pick by probing for the global (not by order, URL
or title, which differ across versions and locales), and refuse loudly with
the target list rather than silently mispicking.
"""

from __future__ import annotations

import asyncio

import pytest

from helpers.cdp import CdpClient, CdpError


def _target(ident: str, title: str = "", url: str = "app://obsidian.md/index.html") -> dict:
    return {
        "type": "page",
        "title": title,
        "url": url,
        "webSocketDebuggerUrl": f"ws://127.0.0.1:9222/devtools/page/{ident}",
    }


@pytest.fixture
def client(monkeypatch):
    c = CdpClient(port=9222)

    def fake_targets():
        return c._fake_targets

    monkeypatch.setattr(c, "_list_page_targets", fake_targets)

    async def fake_probe(ws_url, expr):
        return ws_url in c._fake_app_windows

    monkeypatch.setattr(c, "_probe_target", fake_probe)
    c._fake_targets = []
    c._fake_app_windows = set()
    return c


def test_single_window_is_chosen(client):
    """Obsidian 1.12: one target, and it is the app window."""
    main = _target("main")
    client._fake_targets = [main]
    client._fake_app_windows = {main["webSocketDebuggerUrl"]}

    assert asyncio.run(client._resolve_ws_url()) == main["webSocketDebuggerUrl"]


def test_app_window_wins_even_when_it_is_not_first(client):
    """The regression itself. The settings window sorted first and was picked."""
    settings = _target("settings", title="Settings")
    main = _target("main")
    client._fake_targets = [settings, main]
    client._fake_app_windows = {main["webSocketDebuggerUrl"]}

    assert asyncio.run(client._resolve_ws_url()) == main["webSocketDebuggerUrl"]


def test_no_app_window_raises_with_the_target_list(client):
    """Never fall back to targets[0].

    That fallback is what turned one environment change into fifteen red tests
    reporting a JS error instead of a harness problem. The message must name
    what it saw so the next version bump is diagnosable from the log alone.
    """
    client._fake_targets = [_target("settings", title="Settings")]
    client._fake_app_windows = set()

    with pytest.raises(CdpError) as exc:
        asyncio.run(client._resolve_ws_url())

    assert "Settings" in str(exc.value)
    assert "app window" in str(exc.value)


def test_no_targets_at_all_raises(client):
    client._fake_targets = []

    with pytest.raises(CdpError):
        asyncio.run(client._resolve_ws_url())
