"""Fetch a PUBLISHED plugin build (the exact assets users installed) for upgrade tests.

`ENGRAM_PLUGIN_SRC` is the candidate under test. An upgrade test also needs the
build users are upgrading FROM, and building an old commit from source would
test our build of it, not what shipped. So this pulls the release assets
Obsidian's community-plugin installer downloads: main.js, manifest.json and
styles.css from the GitHub release.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import requests

REPO = "engram-app/Engram-obsidian"
ASSETS = ("main.js", "manifest.json", "styles.css")
CACHE = Path(os.environ.get("E2E_PLUGIN_RELEASE_CACHE", "/tmp/e2e-plugin-releases"))

# The release before the candidate. Bump with each release under test.
PREVIOUS_VERSION = os.environ.get("E2E_PREVIOUS_PLUGIN_VERSION", "1.38.1")


def fetch_release(version: str = PREVIOUS_VERSION) -> Path:
    """Directory holding `version`'s release assets, downloaded once per box."""
    dest = CACHE / version
    if all((dest / a).is_file() for a in ASSETS):
        return dest
    dest.mkdir(parents=True, exist_ok=True)
    for asset in ASSETS:
        url = f"https://github.com/{REPO}/releases/download/{version}/{asset}"
        resp = requests.get(url, timeout=60)
        resp.raise_for_status()
        tmp = dest / f"{asset}.part"
        tmp.write_bytes(resp.content)
        tmp.replace(dest / asset)
    # A tag pointing at the wrong build would make every upgrade assertion
    # meaningless, so check the manifest says what we asked for.
    got = json.loads((dest / "manifest.json").read_text())["version"]
    if got != version:
        raise RuntimeError(f"release {version} ships manifest version {got}")
    return dest


def plugin_version(src: Path) -> str:
    return json.loads((src / "manifest.json").read_text())["version"]
