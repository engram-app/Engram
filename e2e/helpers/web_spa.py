"""Real headless-browser web-SPA peer for cross-client CRDT e2e.

A genuine Chromium peer that drives the actual React SPA served by the backend
(same server + user + vault as the Obsidian/CDP instances), so a browser edit
and an Obsidian edit exercise the true cross-client sync path. The SPA's
CodeMirror 6 editor is the ONLY client on the CRDT *checkpoint* path — the exact
path the Obsidian plugin's REST/legacy write cannot reproduce — which is why a
browser peer is needed to cover web-edit -> Obsidian delivery.

Auth: local-mode email/password against the SPA's sign-in form (the same
`/api/auth/login` flow as ``frontend/e2e/support/api.ts``). Editing mirrors
``frontend/e2e/note-live-update.spec.ts``: focus ``.cm-content`` and
``keyboard.insert_text`` (one atomic CM6 transaction per insert, one CRDT op —
NOT ``type`` which emits one op per character and interleaves under concurrency).

Requires Playwright + Chromium (already in the e2e requirements + CI image).
"""

from __future__ import annotations

import logging
import os
import re

from playwright.async_api import async_playwright

logger = logging.getLogger(__name__)


class WebSpaPeer:
    """A logged-in browser tab on the SPA, editing one note at a time."""

    def __init__(self, base_url: str, email: str, password: str):
        self.base_url = base_url.rstrip("/")
        self.email = email
        self.password = password
        self._pw = None
        self._browser = None
        self._ctx = None
        self._page = None

    async def start(self) -> None:
        self._pw = await async_playwright().start()
        # --no-sandbox: headless Chromium under CI/container users; harmless locally.
        # E2E_WEB_HEADED=1 launches headed (point DISPLAY at an Xvfb): on some
        # dev hosts headless Chromium never produces compositor frames, so
        # requestAnimationFrame stalls and every Playwright actionability wait
        # (visible/enabled/STABLE needs two consecutive frames) times out at
        # the sign-in click. CI runners tick fine headless; this is local-only.
        headed = os.environ.get("E2E_WEB_HEADED") == "1"
        self._browser = await self._pw.chromium.launch(
            headless=not headed, args=["--no-sandbox", "--disable-gpu"]
        )
        self._ctx = await self._browser.new_context(base_url=self.base_url)
        self._page = await self._ctx.new_page()

    async def open_note(self, note_id: str, vault_id: str) -> None:
        """Sign in (if needed) and open ``/note/<note_id>`` in the editor.

        Mirrors ``signInForNote``: navigate to the note, get bounced to the
        sign-in page, seed ``engram.activeVaultId`` BEFORE completing sign-in so
        the value survives the post-sign-in redirect and the first note query
        targets the right vault, then sign in and wait for the editor.
        """
        page = self._page
        await page.goto(f"/note/{note_id}")
        await page.wait_for_url(re.compile(r"/sign-in"), timeout=15_000)

        await page.evaluate(
            "(id) => localStorage.setItem('engram.activeVaultId', String(id))",
            str(vault_id),
        )

        await page.get_by_label("Email").fill(self.email)
        await page.get_by_label("Password", exact=True).fill(self.password)
        await page.get_by_role("button", name=re.compile("sign in", re.I)).click()

        await page.wait_for_url(re.compile(rf"/note/{re.escape(str(note_id))}"), timeout=15_000)
        await self._editor().wait_for(state="visible", timeout=15_000)

    def _editor(self):
        return self._page.locator(".cm-content")

    def editor_locator(self):
        """Public CM6 content locator, for auto-retrying `expect(...)` asserts."""
        return self._editor()

    async def append(self, text: str) -> None:
        """Append `text` at end-of-doc as one atomic CM6 transaction (one CRDT op)."""
        ed = self._editor()
        await ed.click()
        await self._page.keyboard.press("Control+End")
        await self._page.keyboard.insert_text(text)
        # CM6 flushes the transaction to the Y.Doc synchronously; the crdt_msg
        # frame ships on the next tick. Nothing to await here — the receiving
        # side polls for convergence.

    async def read(self) -> str:
        return await self._editor().inner_text()

    async def stop(self) -> None:
        try:
            if self._ctx is not None:
                await self._ctx.close()
            if self._browser is not None:
                await self._browser.close()
            if self._pw is not None:
                await self._pw.stop()
        except Exception as exc:  # teardown must never fail a test
            logger.warning("WebSpaPeer teardown error: %s", exc)
