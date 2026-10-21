"""Test 105: the plugin-first onboarding journey, end to end, in real Obsidian.

A brand-new user already has a vault on disk and installs the plugin. Linking
starts in Obsidian: the plugin opens /link in a browser, the user signs in for
the first time, finishes whatever onboarding the stack shows, confirms the vault
the plugin suggested, and the plugin receives its token. The first sync then
uploads the existing vault, and the server must hold exactly what was on disk.

Nothing here is pre-provisioned through the API: the device code comes from the
plugin, the authorization from a real browser on the real SPA.
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import secrets
import time
from urllib.parse import quote, urlsplit

import pytest
from playwright.async_api import async_playwright

from helpers.api import ApiClient
from helpers.cdp import PLUGIN_PATH, CdpClient
from helpers.clerk import e2e_email
from helpers.clerk_browser import clerk_sign_in_url, install_testing_token
from helpers.quiescence import await_quiescent
from helpers.scenario import timed_step
from helpers.vault import write_binary, write_note

API_URL = os.environ.get("ENGRAM_API_URL") or "http://localhost:8100/api"
SPA_URL = os.environ.get("ENGRAM_SPA_URL") or (
    API_URL[:-4] if API_URL.endswith("/api") else API_URL
)

logger = logging.getLogger(__name__)

pytestmark = pytest.mark.skipif(
    not os.environ.get("E2E_CLERK_SECRET_KEY"),
    reason="E2E_CLERK_SECRET_KEY not set: the journey signs a real Clerk user in",
)

TINY_PNG = (
    b"\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\x00\x00\x01"
    b"\x00\x00\x00\x01\x08\x02\x00\x00\x00\x90wS\xde\x00"
    b"\x00\x00\x0cIDATx\x9cc\xf8\x0f\x00\x00\x01\x01\x00"
    b"\x05\x18\xd8N\x00\x00\x00\x00IEND\xaeB`\x82"
)
ATTACHMENT = "Assets/diagram.png"
FRONTMATTER_NOTE = "Projects/Engram/Roadmap.md"
FRONTMATTER_BODY = (
    "---\ntitle: Roadmap\ntags:\n  - planning\n  - q4\nstatus: draft\n---\n"
    "# Roadmap\n\nShip the plugin-first journey.\n"
)
UNICODE_NOTE = "Journal/Café ☕ 日本語.md"
# Seeded server-side into every new vault (lib/engram/vaults/welcome_note.ex).
WELCOME_NOTE = "Welcome to Engram.md"


def _vault_notes() -> dict[str, str]:
    """20 notes: root, nested folders, one unicode name, one with frontmatter."""
    notes = {f"Inbox/Idea {i}.md": f"# Idea {i}\n\nCaptured before linking.\n" for i in range(6)}
    notes |= {f"Projects/Engram/Spec {i}.md": f"# Spec {i}\n\nSee [[Roadmap]].\n" for i in range(6)}
    notes |= {f"Archive/2025/Q{i}/Review.md": f"# Q{i} review\n" for i in range(1, 5)}
    notes |= {
        "Welcome.md": "# Welcome\n\nMy vault, before Engram.\n",
        "Daily/2026-10-20.md": "- [ ] link the plugin\n",
        UNICODE_NOTE: "# Café\n\nこんにちは, naïve résumé.\n",
        FRONTMATTER_NOTE: FRONTMATTER_BODY,
    }
    assert len(notes) == 20
    return notes


async def _poll(fn, timeout: float, what: str):
    deadline = time.monotonic() + timeout
    while True:
        value = await fn()
        if value:
            return value
        if time.monotonic() >= deadline:
            raise AssertionError(f"timed out after {timeout}s waiting for {what}")
        await asyncio.sleep(0.5)


async def _sign_in_and_link(sign_in_url: str, clerk_client, vault_name: str) -> None:
    """The browser half: first sign-in, onboarding if shown, confirm the vault."""
    async with async_playwright() as pw:
        browser = await pw.chromium.launch(headless=True, args=["--no-sandbox", "--disable-gpu"])
        try:
            context = await browser.new_context(locale="en-US")
            await install_testing_token(context, clerk_client)
            page = await context.new_page()
            await page.goto(sign_in_url)

            sync = page.get_by_role("button", name="Sync", exact=True)
            deadline = time.monotonic() + 60
            while not await sync.is_visible():
                path = urlsplit(page.url).path
                # The CI stack runs billing off, so terms are usually absent.
                if path == "/onboard/agreement":
                    await page.get_by_label(re.compile("I have read and agree", re.I)).click()
                    await page.get_by_role("button", name=re.compile("^continue$", re.I)).click()
                    await page.wait_for_url(lambda u: "/onboard/agreement" not in u, timeout=25_000)
                    continue
                if time.monotonic() >= deadline:
                    raise AssertionError(f"never reached the /link Sync button; at {urlsplit(page.url).path}")
                await asyncio.sleep(0.5)

            assert urlsplit(page.url).path == "/link", f"Sync button off /link: {urlsplit(page.url).path}"
            # The plugin sent its vault name with the device code; a first vault
            # is offered as a new vault seeded with exactly that name.
            suggested = await page.get_by_label("New vault name").input_value()
            assert suggested == vault_name, f"/link suggested {suggested!r}, plugin vault is {vault_name!r}"
            await sync.click()
            await page.get_by_text(re.compile("your vault is linked", re.I)).wait_for(timeout=15_000)
        finally:
            await browser.close()


# staging joins in the canary phase, once the heard step and the staging Clerk testing token are handled.
@pytest.mark.canary(cadence="hourly", targets=["ci"])
@pytest.mark.asyncio
async def test_plugin_first_journey(fresh_unlinked_instance, clerk_client, ts, scenario_steps):
    inst = fresh_unlinked_instance
    notes = _vault_notes()
    email = e2e_email("pluginfirst", ts)
    user_id = None
    passed = False

    try:
        with timed_step("seed-local-vault"):
            for path, body in notes.items():
                write_note(inst.vault_path, path, body)
            write_binary(inst.vault_path, ATTACHMENT, TINY_PNG)
            await inst.async_start(restart=True)
            cdp = CdpClient(port=inst.cdp_port)
            settings = json.loads(await cdp.evaluate(f"JSON.stringify({PLUGIN_PATH}.settings)"))
            assert not settings.get("apiKey") and not settings.get("refreshToken"), (
                "instance must start unlinked"
            )

        with timed_step("start-link-from-plugin"):
            # Plugin surface this depends on: `settingTab.startDeviceFlow()` (src/settings.ts)
            # and DeviceFlowModal's `window.open(verificationUrlWithCode(...))`
            # (src/device-flow-modal.ts). Rename either and this step must follow.
            await cdp.evaluate(
                "window.__engramOpened = []; "
                "window.open = (u) => { window.__engramOpened.push(String(u)); return null; }; "
                f"void {PLUGIN_PATH}.settingTab.startDeviceFlow(); true"
            )
            opened = await _poll(
                lambda: cdp.evaluate("window.__engramOpened[0] || ''"), 30, "the plugin to open /link"
            )
            parts = urlsplit(opened)
            assert parts.path == "/link" and "code=" in parts.query, f"plugin opened {opened!r}"
            link_path = f"{parts.path}?{parts.query}"
            vault_name = await cdp.evaluate("app.vault.getName()")

        with timed_step("browser-sign-in-and-onboard"):
            user_id = clerk_client.create_user(email, secrets.token_urlsafe(24))
            sign_in_url = clerk_sign_in_url(clerk_client, user_id, SPA_URL, link_path)
            await _sign_in_and_link(sign_in_url, clerk_client, vault_name)

        with timed_step("plugin-receives-token"):
            linked = await _poll(
                lambda: cdp.evaluate(
                    f"(() => {{ const s = {PLUGIN_PATH}.settings;"
                    " return s.refreshToken && s.vaultId && s.authMethod === 'oauth'"
                    " ? JSON.stringify({vaultId: s.vaultId, email: s.userEmail}) : ''; })()"
                ),
                60,
                "the plugin's device-flow poll to store its token",
            )
            linked = json.loads(linked)
            assert linked["email"] == email
            token = await cdp.evaluate(f"{PLUGIN_PATH}.api.authProvider.getToken()", await_promise=True)
            assert token, "linked plugin has no access token"
            api = ApiClient(API_URL, token).with_vault(linked["vaultId"])

        with timed_step("first-sync"):
            # Linking opens the first-sync preview. The server vault is not empty:
            # creating it on /link seeds the welcome note, so this is the full
            # preview, and its safe default ("Sync", smart-merge) is the user's click.
            # Pins plugin UI: the `.engram-sync-preview-modal` class, the "Sync" option
            # label and the English plan copy (Obsidian runs with locale en-US).
            await cdp.wait_for_sync_preview_modal(timeout=30)
            plan = "Uploads 21, downloads 1."
            deadline = time.monotonic() + 30
            while plan not in (shown := await cdp.evaluate(
                "document.querySelector('.engram-sync-preview-modal')?.innerText || ''"
            )) and time.monotonic() < deadline:
                await asyncio.sleep(0.5)
            assert plan in shown, f"first-sync preview shows: {shown!r}"
            await cdp.pick_modal_option("Sync")
            await cdp.wait_for_modal_closed(timeout=10)
            await cdp.trigger_full_sync()
            await await_quiescent(cdp, api, deadline_s=90)

        with timed_step("server-has-vault"):
            manifest = api.get_manifest()
            assert sorted(n["path"] for n in manifest["notes"]) == sorted([*notes, WELCOME_NOTE])
            assert [a["path"] for a in manifest["attachments"]] == [ATTACHMENT]
            raw = api.session.get(
                f"{api.base_url}/attachments/{quote(ATTACHMENT, safe='')}",
                params={"raw": "1"},
                timeout=10,
            )
            assert raw.status_code == 200 and raw.content == TINY_PNG
            # Cold CRDT bodies fold in asynchronously; wait for every fold, then
            # demand bytes for all 20 (frontmatter and unicode included).
            deadline = time.monotonic() + 30
            while True:
                server = {p: (api.get_note(p) or {}).get("content") for p in notes}
                differ = sorted(p for p, body in notes.items() if server[p] != body)
                if not differ or time.monotonic() >= deadline:
                    break
                await asyncio.sleep(0.5)
            assert not differ, "server bodies differ from disk: " + "; ".join(
                f"{p}: {server[p]!r}" for p in differ
            )
        passed = True
    finally:
        # The account goes with the Clerk user (session_cleanup sweeps e2e-* rows);
        # DELETE /api/me needs a first-party session and a password, which a
        # device token never has.
        if user_id:
            try:
                clerk_client.delete_user(user_id)
            except Exception:
                logger.exception("teardown: deleting Clerk user %s failed", user_id)
                # Never mask the test's own failure with a teardown error.
                if passed:
                    raise
