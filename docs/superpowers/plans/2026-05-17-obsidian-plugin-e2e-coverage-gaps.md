# Obsidian Plugin E2E Coverage Gaps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Fill 19 identified gaps in E2E coverage for the `engram-vault-sync` Obsidian plugin so that nearly every user-facing path (settings, modals, commands, ribbon, status bar, auth edge cases) has a deterministic regression test running against real Obsidian via CDP.

**Architecture:** Each gap becomes a new pytest file in `engram/e2e/tests/` following the established pattern (`test_NN_topic.py`, session-scoped fixtures `cdp_a`/`vault_a`/`api_sync`, seed-and-restore inside `try/finally`, real Obsidian + CDP). Shared driving logic (DOM queries, button clicks, settings mutation) lives in `engram/e2e/helpers/cdp.py` extensions. No new harness components — we ride existing infrastructure end-to-end.

**Tech Stack:** Python 3.11 + pytest-asyncio, Chrome DevTools Protocol via `helpers/cdp.py` (`CdpClient`), Obsidian AppImage + Xvfb (`helpers/obsidian.py`), `helpers/api.py` `ApiClient` for server-side assertions, `helpers/vault.py` for filesystem reads/writes.

## Conventions (apply to every task)

- All tests live under `/home/open-claw/documents/code-projects/engram/e2e/tests/`.
- File numbering: continue from `test_51_*`. Reserved: 52–71 in this plan.
- Each test module begins with a top docstring describing **what user path it covers** and **why the seed/restore choices are necessary** (echo the `test_51` style).
- Use `pytest.mark.asyncio` on every test function.
- Wrap state-mutating seed in `try/finally` with restore — never leave the gate closed, the conflict handler installed, or seeded files behind. Other tests share the same session.
- Reuse fixtures from `e2e/conftest.py`: `vault_a` / `cdp_a` / `api_sync` for solo-instance tests, add `vault_b` / `cdp_b` for cross-instance flows.
- Plugin id is **`engram-vault-sync`**. Always reference via `app.plugins.plugins['engram-vault-sync']` inside `evaluate()` calls.
- All new CDP helper methods belong on `CdpClient` in `helpers/cdp.py`. Keep them async and minimal — one method per discrete interaction.
- New tests **must skip** gracefully when the plugin SHA loaded by CI lacks an API the test needs. Pattern (from test_51):

  ```python
  @pytest.fixture(autouse=True)
  async def _require_xyz(cdp_a):
      if not await cdp_a.has_xyz():
          pytest.skip("Plugin lacks XYZ — API not present")
  ```

- Each task ends with a commit on a `feat/e2e-NN-<slug>` branch and a PR (see Workflow section in repo CLAUDE.md). The plugin repo CLAUDE.md mandates same for plugin-side changes.

## Workflow per task

1. `cd /home/open-claw/documents/code-projects/engram && git switch -c feat/e2e-NN-<slug>`
2. Write/update CDP helper if needed.
3. Write the failing test.
4. Run only that test: `cd e2e && uv run pytest tests/test_NN_<slug>.py -v` (or whatever the repo's runner script is — check `e2e/README.md`).
5. Iterate until it passes against a freshly-built plugin (`bun run build` in plugin repo, then redeploy the dist via `ENGRAM_PLUGIN_SRC`).
6. Commit, push, open PR.

---

## Phase 1 — High-priority user surface (Tasks 1–7)

These tasks cover the most-trafficked user paths that currently have zero E2E coverage.

### Task 1: Expand `CdpClient` helpers

**Files:**
- Modify: `engram/e2e/helpers/cdp.py`

The new helpers below are referenced by Tasks 2–21. Implement them up front so subsequent tasks just call them.

- [ ] **Step 1: Add SearchModal helpers**

Add after the existing modal helpers (~ line 286):

```python
async def open_search_modal(self) -> None:
    """Run the `search` command — opens SearchModal."""
    await self.evaluate(
        "app.commands.executeCommandById('engram-vault-sync:search')"
    )

async def wait_for_search_modal(self, timeout: float = 5) -> None:
    """Block until the search modal mounts."""
    import asyncio, time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        present = await self.evaluate(
            "Boolean(document.querySelector('.engram-search-modal "
            "input.engram-search-input'))"
        )
        if present:
            return
        await asyncio.sleep(0.1)
    raise TimeoutError("SearchModal did not mount")

async def type_search_query(self, query: str) -> None:
    """Fill the SearchModal input and dispatch input event."""
    await self.evaluate(
        f"(() => {{const i = document.querySelector("
        f"'.engram-search-modal input.engram-search-input'); "
        f"i.value = {json.dumps(query)}; "
        f"i.dispatchEvent(new Event('input', {{bubbles: true}})); }})()"
    )

async def get_search_results(self) -> list[dict]:
    """Snapshot rendered results as [{title, folder, snippet}]."""
    return await self.evaluate(
        "Array.from(document.querySelectorAll("
        "'.engram-search-modal .engram-search-result')).map("
        "el => ({title: el.querySelector('.title')?.textContent, "
        "folder: el.querySelector('.folder')?.textContent, "
        "snippet: el.querySelector('.snippet')?.textContent}))"
    )
```

Add `import json` at top if not present.

- [ ] **Step 2: Add SearchView (sidebar) helpers**

```python
async def open_search_sidebar(self) -> None:
    await self.evaluate(
        "app.commands.executeCommandById("
        "'engram-vault-sync:open-search-sidebar')"
    )

async def wait_for_search_view(self, timeout: float = 5) -> None:
    import asyncio, time
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        present = await self.evaluate(
            "Boolean(document.querySelector('.workspace-leaf-content"
            "[data-type=\"engram-search-view\"]'))"
        )
        if present:
            return
        await asyncio.sleep(0.1)
    raise TimeoutError("SearchView did not mount")
```

- [ ] **Step 3: Add ConflictModal interaction helpers**

```python
async def get_conflict_view_mode(self) -> str:
    """'unified' or 'side-by-side'."""
    return await self.evaluate(
        "document.querySelector('.engram-conflict-modal "
        "[data-view-mode]')?.dataset.viewMode"
    )

async def toggle_conflict_view(self) -> None:
    await self.evaluate(
        "document.querySelector('.engram-conflict-modal "
        ".engram-view-toggle').click()"
    )

async def click_all_local(self) -> None:
    await self.evaluate(
        "document.querySelector('.engram-conflict-modal "
        ".engram-all-local').click()"
    )

async def click_all_remote(self) -> None:
    await self.evaluate(
        "document.querySelector('.engram-conflict-modal "
        ".engram-all-remote').click()"
    )

async def pick_conflict_hunk(self, index: int, side: str) -> None:
    """side ∈ {'local', 'remote'}."""
    await self.evaluate(
        f"document.querySelectorAll('.engram-conflict-modal "
        f".engram-hunk')[{index}].querySelector("
        f"'[data-side=\"{side}\"]').click()"
    )

async def set_merge_editor(self, content: str) -> None:
    await self.evaluate(
        f"(() => {{const t = document.querySelector("
        f"'.engram-conflict-modal textarea.engram-merge-editor'); "
        f"t.value = {json.dumps(content)}; "
        f"t.dispatchEvent(new Event('input', {{bubbles: true}})); }})()"
    )

async def click_conflict_accept(self) -> None:
    await self.evaluate(
        "document.querySelector('.engram-conflict-modal "
        ".engram-accept').click()"
    )

async def click_conflict_skip(self) -> None:
    await self.evaluate(
        "document.querySelector('.engram-conflict-modal "
        ".engram-skip').click()"
    )
```

> **Selector verification gate:** the selectors above are derived from `src/conflict-modal.ts`. **Before committing this task, open `src/conflict-modal.ts` in the plugin repo and confirm every CSS class used matches the source.** Update either the source or the helpers so they line up. Add a class to the source if one is missing — the test should not paper over a missing semantic hook.

- [ ] **Step 4: Add SyncPreviewModal destructive confirm helpers**

```python
async def type_destructive_confirm(self, text: str = "delete") -> None:
    await self.evaluate(
        f"(() => {{const i = document.querySelector("
        f"'.engram-sync-preview-modal input.engram-destructive-confirm'); "
        f"i.value = {json.dumps(text)}; "
        f"i.dispatchEvent(new Event('input', {{bubbles: true}})); }})()"
    )

async def destructive_submit_enabled(self) -> bool:
    return await self.evaluate(
        "(() => {const b = document.querySelector("
        "'.engram-sync-preview-modal .engram-destructive-submit'); "
        "return Boolean(b) && !b.disabled; })()"
    )
```

- [ ] **Step 5: Add Sync Center DOM helpers**

```python
async def open_sync_center(self) -> None:
    await self.evaluate(
        "app.commands.executeCommandById("
        "'engram-vault-sync:open-sync-center')"
    )

async def get_issue_groups(self) -> list[dict]:
    """Returns [{category, count, items: [{path, actions:[...]}]}]"""
    return await self.evaluate(
        "Array.from(document.querySelectorAll("
        "'.engram-sync-center .engram-issue-group')).map(g => ({"
        "category: g.dataset.category, "
        "count: Number(g.dataset.count), "
        "items: Array.from(g.querySelectorAll('.engram-issue')).map(i => "
        "({path: i.dataset.path, actions: Array.from("
        "i.querySelectorAll('button')).map(b => b.textContent.trim())}))"
        "}))"
    )

async def click_issue_action(self, path: str, action: str) -> None:
    """action ∈ {'Open', 'Ignore'}"""
    await self.evaluate(
        f"(() => {{const row = document.querySelector("
        f"'.engram-sync-center .engram-issue[data-path={json.dumps(path)}]'); "
        f"const btn = Array.from(row.querySelectorAll('button')).find("
        f"b => b.textContent.trim() === {json.dumps(action)}); "
        f"btn.click(); }})()"
    )

async def get_ignored_files(self) -> list[str]:
    return await self.evaluate(
        "Array.from(document.querySelectorAll("
        "'.engram-sync-center .engram-ignored-item')).map("
        "el => el.dataset.path)"
    )

async def click_restore_ignored(self, path: str) -> None:
    await self.evaluate(
        f"document.querySelector("
        f"'.engram-sync-center .engram-ignored-item"
        f"[data-path={json.dumps(path)}] .engram-restore').click()"
    )

async def get_activity_entries(self) -> list[dict]:
    return await self.evaluate(
        "Array.from(document.querySelectorAll("
        "'.engram-sync-center .engram-activity-entry')).map(el => ({"
        "action: el.dataset.action, "
        "path: el.dataset.path, "
        "status: el.dataset.status}))"
    )

async def click_clear_activity(self) -> None:
    await self.evaluate(
        "document.querySelector('.engram-sync-center "
        ".engram-clear-activity').click()"
    )
```

> Apply the same selector-verification gate as Task 1 step 3 against `src/sync-center-render.ts`.

- [ ] **Step 6: Add settings/command/status-bar/ribbon helpers**

```python
async def open_settings_tab(self, tab: str) -> None:
    """tab ∈ {'cloud','self-hosted','sync-center','advanced'}"""
    await self.evaluate(
        "app.commands.executeCommandById("
        "'app:open-settings'); app.setting.openTabById("
        f"'engram-vault-sync'); app.setting.activeTab.selectSubtab("
        f"{json.dumps(tab)})"
    )

async def run_command(self, command_id: str) -> None:
    """Plugin command ids have form 'engram-vault-sync:<id>'."""
    full = (
        command_id
        if ':' in command_id
        else f"engram-vault-sync:{command_id}"
    )
    await self.evaluate(
        f"app.commands.executeCommandById({json.dumps(full)})"
    )

async def click_status_bar(self) -> None:
    await self.evaluate(
        "document.querySelector('.status-bar "
        ".engram-status-bar-item').click()"
    )

async def get_status_bar_text(self) -> str:
    return await self.evaluate(
        "document.querySelector('.status-bar "
        ".engram-status-bar-item')?.textContent || ''"
    )

async def click_ribbon(self) -> None:
    await self.evaluate(
        "Array.from(document.querySelectorAll('.side-dock-ribbon-action'))"
        ".find(el => el.getAttribute('aria-label')?.includes('Engram'))"
        ".click()"
    )
```

- [ ] **Step 7: Add `has_*` skip-gate helpers for everything new**

Each new test will autouse-skip when the plugin lacks the surface. Add:

```python
async def has_search_modal(self) -> bool:
    return await self.evaluate(
        "Boolean(app.commands.findCommand("
        "'engram-vault-sync:search'))"
    )

async def has_sync_center(self) -> bool:
    return await self.evaluate(
        "Boolean(app.commands.findCommand("
        "'engram-vault-sync:open-sync-center'))"
    )

async def has_command(self, command_id: str) -> bool:
    return await self.evaluate(
        f"Boolean(app.commands.findCommand("
        f"'engram-vault-sync:{command_id}'))"
    )

async def has_ribbon(self) -> bool:
    return await self.evaluate(
        "Array.from(document.querySelectorAll('.side-dock-ribbon-action'))"
        ".some(el => el.getAttribute('aria-label')?.includes('Engram'))"
    )
```

- [ ] **Step 8: Run the existing suite to confirm no regressions**

```bash
cd /home/open-claw/documents/code-projects/engram/e2e
uv run pytest tests/test_51_sync_preview_modal.py -v
```

Expected: PASS — adding methods to `CdpClient` is purely additive.

- [ ] **Step 9: Commit**

```bash
git add e2e/helpers/cdp.py
git commit -m "feat(e2e): add CDP helpers for search/conflict/sync-center/settings"
```

---

### Task 2: `test_52_search_modal.py`

**Files:**
- Create: `engram/e2e/tests/test_52_search_modal.py`

**User path covered:** Command palette → `Semantic search` → SearchModal → type query → debounce → results → Enter to open file.

- [ ] **Step 1: Write the test file**

```python
"""Test 52: SearchModal end-to-end coverage.

Covers the `Semantic search` command opening SearchModal, typing a query,
the 300ms debounce, results rendering, and Enter-to-open.

Seed strategy: push a known note via the API (so it's indexed server-side),
poll until the embedding is available, then drive the modal via CDP.
"""

from __future__ import annotations
import asyncio
import pytest

from helpers.vault import write_note


SEED_DIR = "E2E/SearchModal"


@pytest.fixture(autouse=True)
async def _require_search(cdp_a):
    if not await cdp_a.has_search_modal():
        pytest.skip("Plugin lacks Semantic search command")


@pytest.mark.asyncio
async def test_search_modal_returns_indexed_note(
    vault_a, cdp_a, api_sync
):
    path = f"{SEED_DIR}/UniqueQueryToken-XYZZY42.md"
    content = "# Photosynthesis primer\n\nUniqueQueryToken-XYZZY42 anchors this test."
    write_note(vault_a, path, content)
    await cdp_a.trigger_full_sync()

    # Wait up to 30s for backend embedding pipeline to index the note.
    deadline = asyncio.get_event_loop().time() + 30
    while asyncio.get_event_loop().time() < deadline:
        hits = api_sync.search("UniqueQueryToken-XYZZY42")
        if hits:
            break
        await asyncio.sleep(1)
    else:
        pytest.fail("Backend never indexed seed note")

    try:
        await cdp_a.open_search_modal()
        await cdp_a.wait_for_search_modal()
        await cdp_a.type_search_query("UniqueQueryToken-XYZZY42")
        # Debounce is 300 ms — wait a touch longer.
        await asyncio.sleep(0.5)
        results = await cdp_a.get_search_results()
        assert any(path.endswith(r["title"]) for r in results), (
            f"Expected seed in results, got {results!r}"
        )
    finally:
        (vault_a / path).unlink(missing_ok=True)
        await cdp_a.trigger_full_sync()


@pytest.mark.asyncio
async def test_search_modal_empty_query_shows_hint(vault_a, cdp_a):
    try:
        await cdp_a.open_search_modal()
        await cdp_a.wait_for_search_modal()
        await cdp_a.type_search_query("")
        await asyncio.sleep(0.5)
        empty_visible = await cdp_a.evaluate(
            "Boolean(document.querySelector("
            "'.engram-search-modal .engram-search-empty'))"
        )
        assert empty_visible, "Empty-state hint should render for empty query"
    finally:
        await cdp_a.evaluate(
            "document.querySelectorAll('.modal-container .modal').forEach("
            "m => m.dispatchEvent(new KeyboardEvent('keydown', "
            "{key: 'Escape', bubbles: true})))"
        )
```

- [ ] **Step 2: If `api_sync.search()` does not exist, add it**

Open `engram/e2e/helpers/api.py`. If no `search` method, add:

```python
def search(self, query: str, folder: str | None = None) -> list[dict]:
    body = {"query": query}
    if folder:
        body["folder"] = folder
    return self._post("/search", body).get("results", [])
```

- [ ] **Step 3: Run the test**

```bash
cd /home/open-claw/documents/code-projects/engram/e2e
uv run pytest tests/test_52_search_modal.py -v
```

Expected: both tests PASS.

- [ ] **Step 4: Commit + PR**

```bash
git add e2e/tests/test_52_search_modal.py e2e/helpers/api.py
git commit -m "test(e2e): SearchModal indexed-note round-trip + empty-state"
git push -u origin feat/e2e-52-search-modal
gh pr create --fill
```

---

### Task 3: `test_53_search_view.py`

**Files:**
- Create: `engram/e2e/tests/test_53_search_view.py`

**User path covered:** Command `Open search sidebar` or ribbon click → SearchView mounts in right sidebar → query → results → click to open.

- [ ] **Step 1: Write the test**

```python
"""Test 53: SearchView sidebar end-to-end coverage."""

from __future__ import annotations
import asyncio
import pytest
from helpers.vault import write_note

SEED_DIR = "E2E/SearchView"


@pytest.fixture(autouse=True)
async def _require_sidebar(cdp_a):
    if not await cdp_a.has_command("open-search-sidebar"):
        pytest.skip("Plugin lacks open-search-sidebar command")


@pytest.mark.asyncio
async def test_command_opens_sidebar(cdp_a):
    await cdp_a.open_search_sidebar()
    await cdp_a.wait_for_search_view()
    present = await cdp_a.evaluate(
        "Boolean(document.querySelector('.workspace-leaf-content"
        "[data-type=\"engram-search-view\"]'))"
    )
    assert present


@pytest.mark.asyncio
async def test_ribbon_opens_sidebar(cdp_a):
    if not await cdp_a.has_ribbon():
        pytest.skip("Ribbon icon not registered")
    await cdp_a.click_ribbon()
    await cdp_a.wait_for_search_view()


@pytest.mark.asyncio
async def test_sidebar_search_returns_results(vault_a, cdp_a, api_sync):
    path = f"{SEED_DIR}/SidebarToken-QRX99.md"
    write_note(vault_a, path, "SidebarToken-QRX99 anchor")
    await cdp_a.trigger_full_sync()

    deadline = asyncio.get_event_loop().time() + 30
    while asyncio.get_event_loop().time() < deadline:
        if api_sync.search("SidebarToken-QRX99"):
            break
        await asyncio.sleep(1)

    try:
        await cdp_a.open_search_sidebar()
        await cdp_a.wait_for_search_view()
        await cdp_a.evaluate(
            "(() => {const i = document.querySelector("
            "'.workspace-leaf-content[data-type=\"engram-search-view\"] "
            "input.engram-search-input'); "
            "i.value = 'SidebarToken-QRX99'; "
            "i.dispatchEvent(new Event('input', {bubbles: true}));})()"
        )
        await asyncio.sleep(0.5)
        count = await cdp_a.evaluate(
            "document.querySelectorAll("
            "'.workspace-leaf-content[data-type=\"engram-search-view\"] "
            ".engram-search-result').length"
        )
        assert count >= 1, f"Expected ≥1 result, got {count}"
    finally:
        (vault_a / path).unlink(missing_ok=True)
        await cdp_a.trigger_full_sync()
```

- [ ] **Step 2: Run + commit + PR**

```bash
uv run pytest tests/test_53_search_view.py -v
git add e2e/tests/test_53_search_view.py
git commit -m "test(e2e): SearchView sidebar command/ribbon/results"
gh pr create --fill
```

---

### Task 4: `test_54_conflict_modal_ui.py`

**Files:**
- Create: `engram/e2e/tests/test_54_conflict_modal_ui.py`

**User path covered:** ConflictModal Unified↔Side-by-side toggle, All-local / All-remote bulk buttons, per-hunk choice radios, manual merge editor textarea.

Setup uses the existing conflict-induction pattern from `test_07_conflict_merge.py` (set conflict resolution to `modal`, write same file on A and B with overlapping edits, wait for modal on A).

- [ ] **Step 1: Skim `test_07_conflict_merge.py` and `helpers/conflict.py` to copy the modal-trigger seed pattern.**

- [ ] **Step 2: Write the test file**

```python
"""Test 54: ConflictModal UI interactions — view toggle, bulk buttons,
per-hunk choices, manual merge editor.

Driver seeds a conflict whose hunks are independent (test all-local/all-remote
flip cleanly), then verifies the modal's UI without ever hitting Accept until
the very end of each test (we want the modal still mounted so we can read
state).
"""

from __future__ import annotations
import pytest
from helpers.conflict import setup_conflict_for_a, restore_after_conflict
from helpers.vault import read_note


@pytest.fixture(autouse=True)
async def _set_modal_mode(cdp_a):
    await cdp_a.set_conflict_resolution("modal")
    yield
    await cdp_a.set_conflict_resolution("auto")


@pytest.mark.asyncio
async def test_view_toggle_switches_mode(
    vault_a, vault_b, cdp_a, cdp_b
):
    path = "E2E/Conflict54/ViewToggle.md"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path,
        local="# L1\nlocal\n# L2\nshared\n",
        remote="# L1\nremote\n# L2\nshared\n",
    )
    try:
        mode = await cdp_a.get_conflict_view_mode()
        assert mode == "unified"
        await cdp_a.toggle_conflict_view()
        mode = await cdp_a.get_conflict_view_mode()
        assert mode == "side-by-side"
    finally:
        await cdp_a.click_conflict_skip()
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_all_local_then_accept_writes_local(
    vault_a, vault_b, cdp_a, cdp_b
):
    path = "E2E/Conflict54/AllLocal.md"
    local = "# L1\nlocal-A\n"
    remote = "# L1\nremote-B\n"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path, local=local, remote=remote
    )
    try:
        await cdp_a.click_all_local()
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_modal_closed()
        assert "local-A" in read_note(vault_a, path)
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_all_remote_then_accept_writes_remote(
    vault_a, vault_b, cdp_a, cdp_b
):
    path = "E2E/Conflict54/AllRemote.md"
    local = "# L1\nlocal-A\n"
    remote = "# L1\nremote-B\n"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path, local=local, remote=remote
    )
    try:
        await cdp_a.click_all_remote()
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_modal_closed()
        assert "remote-B" in read_note(vault_a, path)
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_per_hunk_choices(vault_a, vault_b, cdp_a, cdp_b):
    path = "E2E/Conflict54/PerHunk.md"
    local = "# H1\nlocal-1\n# H2\nlocal-2\n"
    remote = "# H1\nremote-1\n# H2\nremote-2\n"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path, local=local, remote=remote
    )
    try:
        await cdp_a.pick_conflict_hunk(0, "local")
        await cdp_a.pick_conflict_hunk(1, "remote")
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_modal_closed()
        merged = read_note(vault_a, path)
        assert "local-1" in merged and "remote-2" in merged
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)


@pytest.mark.asyncio
async def test_manual_merge_editor(vault_a, vault_b, cdp_a, cdp_b):
    path = "E2E/Conflict54/ManualEditor.md"
    await setup_conflict_for_a(
        vault_a, vault_b, cdp_a, cdp_b, path,
        local="# H1\nA\n", remote="# H1\nB\n",
    )
    try:
        await cdp_a.set_merge_editor("# H1\nhand-edited\n")
        await cdp_a.click_conflict_accept()
        await cdp_a.wait_for_modal_closed()
        assert "hand-edited" in read_note(vault_a, path)
    finally:
        await restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path)
```

- [ ] **Step 3: Add `setup_conflict_for_a` / `restore_after_conflict` to `helpers/conflict.py` if not present**

Check `helpers/conflict.py` first. If a similar helper exists (it does in test_07), expose it. Otherwise add:

```python
async def setup_conflict_for_a(
    vault_a, vault_b, cdp_a, cdp_b, path, *, local: str, remote: str
):
    """Push `remote` to server via B, then seed `local` on A so a pull
    finds divergence and opens the modal in 'modal' mode.

    Caller is responsible for restoring (delete file, accept gate).
    """
    from helpers.vault import write_note
    write_note(vault_b, path, remote)
    await cdp_b.trigger_full_sync()
    await cdp_a.pause_outgoing_sync()
    write_note(vault_a, path, local)
    await cdp_a.resume_outgoing_sync()
    await cdp_a.trigger_pull()
    # Modal appears asynchronously — wait.
    import asyncio, time
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if await cdp_a.evaluate(
            "Boolean(document.querySelector('.engram-conflict-modal'))"
        ):
            return
        await asyncio.sleep(0.2)
    raise TimeoutError("ConflictModal never opened")


async def restore_after_conflict(vault_a, vault_b, cdp_a, cdp_b, path):
    (vault_a / path).unlink(missing_ok=True)
    (vault_b / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
    await cdp_b.trigger_full_sync()
```

- [ ] **Step 4: Run + commit + PR**

---

### Task 5: `test_55_sync_preview_destructive.py`

**Files:**
- Create: `engram/e2e/tests/test_55_sync_preview_destructive.py`

**User path covered:** SyncPreviewModal destructive paths (`push-all-delete-remote`, `pull-all-delete-local`) — type-"delete" gate, submit button disabled until correct text, cancel from confirm view.

- [ ] **Step 1: Write the test**

```python
"""Test 55: Destructive confirm view in SyncPreviewModal.

Pre-PR-61 plugins lack the typed-confirm input — skip cleanly there.
"""

from __future__ import annotations
import pytest
from helpers.vault import write_note


SEED_DIR = "E2E/Preview55"


@pytest.fixture(autouse=True)
async def _require_gate(cdp_a):
    if not await cdp_a.has_sync_gate():
        pytest.skip("Plugin lacks SyncPreviewModal")


async def _seed_local_only(cdp, vault, path, content):
    await cdp.pause_outgoing_sync()
    write_note(vault, path, content)
    await cdp.reset_sync_gate()


async def _restore_clean(cdp, vault, path):
    (vault / path).unlink(missing_ok=True)
    await cdp.resume_outgoing_sync()
    await cdp.accept_sync_gate()


@pytest.mark.parametrize(
    "label", ["Push all + delete remote", "Pull all + delete local"]
)
@pytest.mark.asyncio
async def test_destructive_submit_locked_until_typed(
    vault_a, cdp_a, label
):
    path = f"{SEED_DIR}/Lock.md"
    await _seed_local_only(cdp_a, vault_a, path, "# seed")
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()
        await cdp_a.pick_modal_option(label)

        assert not await cdp_a.destructive_submit_enabled(), (
            "Submit must be disabled before user types 'delete'"
        )
        await cdp_a.type_destructive_confirm("delet")
        assert not await cdp_a.destructive_submit_enabled()
        await cdp_a.type_destructive_confirm("delete")
        assert await cdp_a.destructive_submit_enabled()

        # Escape to back out — gate stays closed.
        await cdp_a.evaluate(
            "document.querySelectorAll('.modal-container .modal').forEach("
            "m => m.dispatchEvent(new KeyboardEvent('keydown', "
            "{key: 'Escape', bubbles: true})))"
        )
        await cdp_a.wait_for_modal_closed()
        assert await cdp_a.is_sync_blocked()
    finally:
        await _restore_clean(cdp_a, vault_a, path)


@pytest.mark.asyncio
async def test_destructive_confirm_dispatches_choice(vault_a, cdp_a):
    path = f"{SEED_DIR}/Dispatch.md"
    await _seed_local_only(cdp_a, vault_a, path, "# seed")
    await cdp_a.install_choice_spy(swallow=True)
    try:
        await cdp_a.open_sync_preview_modal()
        await cdp_a.wait_for_sync_preview_modal()
        await cdp_a.pick_modal_option("Push all + delete remote")
        await cdp_a.type_destructive_confirm("delete")
        await cdp_a.click_modal_confirm()
        await cdp_a.wait_for_modal_closed(timeout=10)
        recorded = await cdp_a.get_last_sync_choice()
        assert recorded == "push-all-delete-remote"
    finally:
        await cdp_a.uninstall_choice_spy()
        await _restore_clean(cdp_a, vault_a, path)
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 6: `test_56_sync_center_issues.py`

**Files:**
- Create: `engram/e2e/tests/test_56_sync_center_issues.py`

**User path covered:** Sync Center → Issues panel after a failed push (e.g. too_large) → grouped by category → click "Open" → click "Ignore" → file moves to Ignored panel.

- [ ] **Step 1: Write the test**

```python
"""Test 56: Sync Center Issues panel — categorization, Open/Ignore actions."""

from __future__ import annotations
import pytest
from helpers.vault import write_note


SEED_DIR = "E2E/Issues56"


@pytest.fixture(autouse=True)
async def _require_sync_center(cdp_a):
    if not await cdp_a.has_sync_center():
        pytest.skip("Plugin lacks open-sync-center command")


@pytest.mark.asyncio
async def test_too_large_issue_appears_and_can_be_ignored(
    vault_a, cdp_a
):
    """An 11 MB note is rejected by the backend (test_26 covers the
    rejection itself); we verify the issue surfaces in Sync Center and
    that Ignore moves it to the Ignored panel."""
    path = f"{SEED_DIR}/Huge.md"
    # ~11 MB of ASCII; the backend's max is 10 MB.
    write_note(vault_a, path, "x" * (11 * 1024 * 1024))
    await cdp_a.trigger_full_sync()

    await cdp_a.open_sync_center()
    groups = await cdp_a.get_issue_groups()
    too_large = next(
        (g for g in groups if g["category"] == "too_large"), None
    )
    assert too_large is not None, f"too_large group missing: {groups!r}"
    assert any(i["path"].endswith("Huge.md") for i in too_large["items"])

    await cdp_a.click_issue_action(path, "Ignore")
    ignored = await cdp_a.get_ignored_files()
    assert any(p.endswith("Huge.md") for p in ignored)

    # Cleanup
    (vault_a / path).unlink(missing_ok=True)
    await cdp_a.click_restore_ignored(path)
    await cdp_a.trigger_full_sync()
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 7: `test_57_sync_center_log.py`

**Files:**
- Create: `engram/e2e/tests/test_57_sync_center_log.py`

**User path covered:** Activity log appends on push/pull/delete/error, Clear button empties it. Ignored panel Restore round-trip (re-ingests file).

- [ ] **Step 1: Write the test**

```python
"""Test 57: Sync Center activity log + Ignored panel Restore."""

from __future__ import annotations
import pytest
from helpers.vault import write_note


SEED_DIR = "E2E/Activity57"


@pytest.fixture(autouse=True)
async def _require_sync_center(cdp_a):
    if not await cdp_a.has_sync_center():
        pytest.skip("Plugin lacks open-sync-center command")


@pytest.mark.asyncio
async def test_activity_log_records_push_then_clears(vault_a, cdp_a):
    path = f"{SEED_DIR}/Logged.md"
    write_note(vault_a, path, "# logged")
    await cdp_a.trigger_full_sync()

    await cdp_a.open_sync_center()
    entries = await cdp_a.get_activity_entries()
    assert any(
        e["path"].endswith("Logged.md") and e["action"] == "push"
        for e in entries
    ), f"push entry missing: {entries!r}"

    await cdp_a.click_clear_activity()
    after = await cdp_a.get_activity_entries()
    assert after == []

    (vault_a / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()


@pytest.mark.asyncio
async def test_restore_ignored_resyncs_file(vault_a, cdp_a, api_sync):
    """Ignore a file → confirm not on server → Restore → confirm pushed."""
    path = f"{SEED_DIR}/Restored.md"
    write_note(vault_a, path, "# restored")
    await cdp_a.trigger_full_sync()

    await cdp_a.open_sync_center()
    await cdp_a.click_issue_action(path, "Ignore")  # works for clean files too if button exists
    # Delete from server to simulate Ignored-while-server-gone
    api_sync.delete_note(path)
    assert not api_sync.get_note(path)

    await cdp_a.click_restore_ignored(path)
    await cdp_a.trigger_full_sync()
    assert api_sync.get_note(path) is not None

    api_sync.delete_note(path)
    (vault_a / path).unlink(missing_ok=True)
```

> **Open question to resolve during implementation:** the plugin currently only exposes per-file Ignore in the Issues panel (not arbitrary files). If `click_issue_action` cannot find an Ignore button for a clean file, drop the restore test to a manual-ignore path (mutate `settings.ignoredFiles` via CDP, save, render). Document whichever pivot you take in the test docstring.

- [ ] **Step 2: Run + commit + PR**

---

## Phase 2 — Lifecycle & commands (Tasks 8–13)

### Task 8: `test_58_commands_palette.py`

**Files:**
- Create: `engram/e2e/tests/test_58_commands_palette.py`

**User path covered:** Every plugin command registered in `addCommand` invokable from command palette and produces the documented side effect.

- [ ] **Step 1: Confirm the list from `src/main.ts`**

Read the plugin's `main.ts` and list every `this.addCommand({ id: "..."` call. Update the table below if reality differs.

| Command id | Expected side effect |
|---|---|
| `sync-now` | `lastSync` timestamp advances |
| `push-all` | `pushAll()` invoked (verify via spy) |
| `pull-all` | `pullAll()` invoked (verify via spy) |
| `check-sync` | Notice with missing/diverged counts |
| `show-sync-log` | `.engram-sync-log-modal` mounts |
| `search` | already covered by test_52 — skip here |
| `open-search-sidebar` | already covered by test_53 — skip here |
| `open-sync-center` | already covered by test_56 — skip here |

- [ ] **Step 2: Write the test**

```python
"""Test 58: Plugin command palette entries each fire their handler."""

from __future__ import annotations
import asyncio
import pytest


@pytest.mark.asyncio
async def test_sync_now_advances_last_sync(cdp_a):
    before = await cdp_a.get_last_sync()
    await cdp_a.run_command("sync-now")
    await asyncio.sleep(1)
    after = await cdp_a.get_last_sync()
    assert after != before


@pytest.mark.asyncio
async def test_push_all_invokes_handler(cdp_a):
    if not await cdp_a.has_command("push-all"):
        pytest.skip("Plugin lacks push-all command")
    await cdp_a.evaluate(
        "window.__e2e_pushAll = 0; const p = app.plugins.plugins"
        "['engram-vault-sync']; const orig = p.syncEngine.pushAll.bind("
        "p.syncEngine); p.syncEngine.pushAll = async (...a) => "
        "{window.__e2e_pushAll++; return orig(...a);}"
    )
    try:
        await cdp_a.run_command("push-all")
        await asyncio.sleep(0.5)
        called = await cdp_a.evaluate("window.__e2e_pushAll")
        assert called >= 1
    finally:
        await cdp_a.evaluate(
            "const p = app.plugins.plugins['engram-vault-sync']; "
            "delete window.__e2e_pushAll; delete p.syncEngine._origPushAll"
        )


@pytest.mark.asyncio
async def test_pull_all_invokes_handler(cdp_a):
    if not await cdp_a.has_command("pull-all"):
        pytest.skip("Plugin lacks pull-all command")
    await cdp_a.evaluate(
        "window.__e2e_pullAll = 0; const p = app.plugins.plugins"
        "['engram-vault-sync']; const orig = p.syncEngine.pullAll.bind("
        "p.syncEngine); p.syncEngine.pullAll = async (...a) => "
        "{window.__e2e_pullAll++; return orig(...a);}"
    )
    try:
        await cdp_a.run_command("pull-all")
        await asyncio.sleep(0.5)
        called = await cdp_a.evaluate("window.__e2e_pullAll")
        assert called >= 1
    finally:
        await cdp_a.evaluate("delete window.__e2e_pullAll")


@pytest.mark.asyncio
async def test_check_sync_emits_notice(cdp_a):
    if not await cdp_a.has_command("check-sync"):
        pytest.skip("Plugin lacks check-sync command")
    await cdp_a.evaluate(
        "window.__e2e_notices = []; const origNotice = window.Notice; "
        "window.Notice = function(msg, ms){window.__e2e_notices.push(String(msg)); "
        "return new origNotice(msg, ms);}"
    )
    try:
        await cdp_a.run_command("check-sync")
        await asyncio.sleep(2)
        notices = await cdp_a.evaluate("window.__e2e_notices")
        assert any("sync" in n.lower() for n in notices)
    finally:
        await cdp_a.evaluate(
            "delete window.__e2e_notices; "
            "window.Notice = window.Notice.__wrapped__ || window.Notice"
        )


@pytest.mark.asyncio
async def test_show_sync_log_mounts(cdp_a):
    if not await cdp_a.has_command("show-sync-log"):
        pytest.skip("Plugin lacks show-sync-log command")
    await cdp_a.run_command("show-sync-log")
    mounted = await cdp_a.evaluate(
        "Boolean(document.querySelector('.engram-sync-log-modal'))"
    )
    assert mounted
    await cdp_a.evaluate(
        "document.querySelectorAll('.modal-container .modal').forEach("
        "m => m.dispatchEvent(new KeyboardEvent('keydown', "
        "{key: 'Escape', bubbles: true})))"
    )
```

- [ ] **Step 3: Run + commit + PR**

---

### Task 9: `test_59_status_bar_click.py`

**Files:**
- Create: `engram/e2e/tests/test_59_status_bar_click.py`

**User path covered:** Click status bar → if gate blocked, opens SyncPreviewModal; if not, triggers full sync.

- [ ] **Step 1: Write the test**

```python
"""Test 59: Status bar click behavior — gate state branches."""

from __future__ import annotations
import asyncio
import pytest
from helpers.vault import write_note


@pytest.fixture(autouse=True)
async def _require_gate(cdp_a):
    if not await cdp_a.has_sync_gate():
        pytest.skip("Plugin lacks SyncPreviewModal")


@pytest.mark.asyncio
async def test_click_blocked_opens_modal(vault_a, cdp_a):
    path = "E2E/StatusBar59/Block.md"
    await cdp_a.pause_outgoing_sync()
    write_note(vault_a, path, "# seed")
    await cdp_a.reset_sync_gate()
    try:
        await cdp_a.click_status_bar()
        await cdp_a.wait_for_sync_preview_modal()
    finally:
        await cdp_a.evaluate(
            "document.querySelectorAll('.modal-container .modal').forEach("
            "m => m.dispatchEvent(new KeyboardEvent('keydown', "
            "{key: 'Escape', bubbles: true})))"
        )
        (vault_a / path).unlink(missing_ok=True)
        await cdp_a.resume_outgoing_sync()
        await cdp_a.accept_sync_gate()


@pytest.mark.asyncio
async def test_click_unblocked_triggers_sync(cdp_a):
    before = await cdp_a.get_last_sync()
    await cdp_a.click_status_bar()
    await asyncio.sleep(1.5)
    after = await cdp_a.get_last_sync()
    assert after != before
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 10: `test_60_ribbon_icon.py`

Covered in part by Task 3 (`test_ribbon_opens_sidebar`). **Skip Task 10 if Task 3 already covers it.** Otherwise add a dedicated test for the ribbon icon's `aria-label` and its presence in the actions panel.

---

### Task 11: `test_61_sync_progress_modal.py`

**Files:**
- Create: `engram/e2e/tests/test_61_sync_progress_modal.py`

**User path covered:** During a bulk push/pull, SyncProgressModal renders phase labels, progress bar advances, "Run in background" closes the modal but sync continues.

- [ ] **Step 1: Add CDP helpers**

In `helpers/cdp.py`:

```python
async def get_progress_phase(self) -> str | None:
    return await self.evaluate(
        "document.querySelector("
        "'.engram-sync-progress-modal .engram-phase')?.textContent"
    )

async def get_progress_percent(self) -> int | None:
    return await self.evaluate(
        "(() => {const el = document.querySelector("
        "'.engram-sync-progress-modal progress'); "
        "return el ? Number(el.value) : null;})()"
    )

async def click_progress_background(self) -> None:
    await self.evaluate(
        "document.querySelector("
        "'.engram-sync-progress-modal .engram-bg-btn').click()"
    )
```

- [ ] **Step 2: Write the test**

```python
"""Test 61: SyncProgressModal phases + 'Run in background'."""

from __future__ import annotations
import asyncio
import pytest
from helpers.vault import write_note


SEED_DIR = "E2E/Progress61"


@pytest.mark.asyncio
async def test_phases_advance_and_bg_button_closes(vault_a, cdp_a):
    # Seed 50 files so a push-all takes long enough to observe phases.
    for i in range(50):
        write_note(vault_a, f"{SEED_DIR}/n{i}.md", f"# n{i}\n" * 10)

    seen_phases: set[str] = set()
    asyncio.create_task(
        cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync'].syncEngine.pushAll()",
            await_promise=True,
        )
    )
    for _ in range(40):
        phase = await cdp_a.get_progress_phase()
        if phase:
            seen_phases.add(phase)
        await asyncio.sleep(0.25)

    assert any("Push" in p for p in seen_phases), (
        f"Expected a 'Push…' phase, got {seen_phases!r}"
    )

    if await cdp_a.evaluate(
        "Boolean(document.querySelector("
        "'.engram-sync-progress-modal .engram-bg-btn'))"
    ):
        await cdp_a.click_progress_background()
        await cdp_a.wait_for_modal_closed()

    # Cleanup
    for i in range(50):
        (vault_a / f"{SEED_DIR}/n{i}.md").unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
```

- [ ] **Step 3: Run + commit + PR**

---

### Task 12: `test_62_sync_log_modal.py`

**Files:**
- Create: `engram/e2e/tests/test_62_sync_log_modal.py`

**User path covered:** SyncLogModal renders entries, error rows expand to show stack/message.

- [ ] **Step 1: Write the test**

```python
"""Test 62: SyncLogModal rendering."""

from __future__ import annotations
import pytest
from helpers.vault import write_note


@pytest.fixture(autouse=True)
async def _require_log(cdp_a):
    if not await cdp_a.has_command("show-sync-log"):
        pytest.skip("Plugin lacks show-sync-log command")


@pytest.mark.asyncio
async def test_log_shows_recent_push(vault_a, cdp_a):
    path = "E2E/Log62/Entry.md"
    write_note(vault_a, path, "# log entry")
    await cdp_a.trigger_full_sync()

    await cdp_a.run_command("show-sync-log")
    rows = await cdp_a.evaluate(
        "Array.from(document.querySelectorAll("
        "'.engram-sync-log-modal .engram-log-row')).map(r => "
        "({action: r.dataset.action, path: r.dataset.path, "
        "status: r.dataset.status}))"
    )
    assert any(
        r["path"].endswith("Entry.md") and r["action"] == "push"
        for r in rows
    )

    await cdp_a.evaluate(
        "document.querySelectorAll('.modal-container .modal').forEach("
        "m => m.dispatchEvent(new KeyboardEvent('keydown', "
        "{key: 'Escape', bubbles: true})))"
    )
    (vault_a / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 13: `test_63_device_flow_edge.py`

**Files:**
- Create: `engram/e2e/tests/test_63_device_flow_edge.py`

**User path covered:** DeviceFlowModal expired-code screen + Cancel screen. Success path is already in `test_44_oauth_device_flow.py`.

- [ ] **Step 1: Write the test**

```python
"""Test 63: DeviceFlowModal expired + cancel paths.

Drives the modal directly: simulate a 410 GONE from /auth/device/token to
land on the expired screen, then click Cancel from the in-progress screen.
"""

from __future__ import annotations
import pytest


@pytest.fixture(autouse=True)
async def _require_oauth(cdp_a):
    if not await cdp_a.evaluate(
        "Boolean(app.plugins.plugins['engram-vault-sync']."
        "openDeviceFlowModal)"
    ):
        pytest.skip("Plugin lacks DeviceFlowModal hook")


@pytest.mark.asyncio
async def test_expired_state(cdp_a):
    """Stub the polling fetch to immediately return 410 → expired screen."""
    await cdp_a.evaluate(
        "(() => {const realFetch = window.fetch.bind(window); "
        "window.__e2e_realFetch = realFetch; "
        "window.fetch = async (url, opts) => { "
        "if (String(url).includes('/auth/device/token')) "
        "return new Response('{}', {status: 410}); "
        "return realFetch(url, opts); };})()"
    )
    try:
        await cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync']."
            "openDeviceFlowModal()"
        )
        # Modal polls every 5 s — wait for expired branch.
        import asyncio, time
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            expired = await cdp_a.evaluate(
                "Boolean(document.querySelector('.engram-device-flow-modal "
                ".engram-expired'))"
            )
            if expired:
                break
            await asyncio.sleep(0.5)
        assert expired
    finally:
        await cdp_a.evaluate(
            "window.fetch = window.__e2e_realFetch; "
            "delete window.__e2e_realFetch;"
            "document.querySelectorAll('.modal-container .modal').forEach("
            "m => m.dispatchEvent(new KeyboardEvent('keydown', "
            "{key: 'Escape', bubbles: true})))"
        )


@pytest.mark.asyncio
async def test_cancel_closes_modal(cdp_a):
    await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync']."
        "openDeviceFlowModal()"
    )
    import asyncio
    await asyncio.sleep(1)
    await cdp_a.evaluate(
        "document.querySelector('.engram-device-flow-modal "
        ".engram-cancel').click()"
    )
    await cdp_a.wait_for_modal_closed()
```

- [ ] **Step 2: Run + commit + PR**

---

## Phase 3 — Settings, auth, and edge cases (Tasks 14–21)

### Task 14: `test_64_settings_interactions.py`

**Files:**
- Create: `engram/e2e/tests/test_64_settings_interactions.py`

**User path covered:** Vault switching from settings, conflict-mode dropdown, debounce field, custom ignore patterns textarea — each persists across plugin reload.

- [ ] **Step 1: Write the test**

```python
"""Test 64: Settings tabs — persistence of user-edited values."""

from __future__ import annotations
import pytest


@pytest.mark.asyncio
async def test_conflict_mode_persists(cdp_a):
    await cdp_a.set_conflict_resolution("modal")
    await cdp_a.reload_plugin()
    mode = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync']."
        "settings.conflictResolution"
    )
    assert mode == "modal"
    await cdp_a.set_conflict_resolution("auto")


@pytest.mark.asyncio
async def test_debounce_value_persists(cdp_a):
    await cdp_a.evaluate(
        "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
        "p.settings.debounceMs = 4321; await p.saveSettings();})()",
        await_promise=True,
    )
    await cdp_a.reload_plugin()
    val = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].settings.debounceMs"
    )
    assert val == 4321
    # Restore default
    await cdp_a.evaluate(
        "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
        "p.settings.debounceMs = 2000; await p.saveSettings();})()",
        await_promise=True,
    )


@pytest.mark.asyncio
async def test_custom_ignore_patterns_persist(cdp_a):
    await cdp_a.evaluate(
        "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
        "p.settings.ignorePatterns = ['**/scratch/**']; "
        "await p.saveSettings();})()",
        await_promise=True,
    )
    await cdp_a.reload_plugin()
    patterns = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].settings.ignorePatterns"
    )
    assert patterns == ["**/scratch/**"]
    # Verify shouldIgnore honors it
    ignored = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].syncEngine."
        "shouldIgnore('foo/scratch/bar.md')"
    )
    assert ignored is True
    # Restore
    await cdp_a.evaluate(
        "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
        "p.settings.ignorePatterns = []; await p.saveSettings();})()",
        await_promise=True,
    )
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 15: `test_65_problem_dir_scanner.py`

**Files:**
- Create: `engram/e2e/tests/test_65_problem_dir_scanner.py`

**User path covered:** Plugin detects `node_modules/`, surfaces it in Advanced tab, "Add to ignores" button appends the glob to settings.

- [ ] **Step 1: Write the test**

```python
"""Test 65: Problem-dir scanner — detect node_modules and offer ignore."""

from __future__ import annotations
import pytest


@pytest.mark.asyncio
async def test_node_modules_detected_and_addable(vault_a, cdp_a):
    junk = vault_a / "node_modules" / "junk"
    junk.mkdir(parents=True, exist_ok=True)
    (junk / "a.md").write_text("noise")
    try:
        detected = await cdp_a.evaluate(
            "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
            "return await p.scanProblemDirs();})()",
            await_promise=True,
        )
        assert any(d.get("dir") == "node_modules" for d in (detected or [])), (
            f"node_modules not detected: {detected!r}"
        )

        await cdp_a.evaluate(
            "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
            "await p.addProblemDirToIgnores('node_modules');})()",
            await_promise=True,
        )
        patterns = await cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync']."
            "settings.ignorePatterns"
        )
        assert any("node_modules" in p for p in patterns)
    finally:
        await cdp_a.evaluate(
            "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
            "p.settings.ignorePatterns = []; await p.saveSettings();})()",
            await_promise=True,
        )
        import shutil
        shutil.rmtree(vault_a / "node_modules", ignore_errors=True)
```

> If `scanProblemDirs` / `addProblemDirToIgnores` are not exposed on the plugin instance, drive the same logic through the settings UI render path (`app.setting.open()` → render Advanced tab → click button). Adjust selectors as needed; verify against `src/settings.ts`.

- [ ] **Step 2: Run + commit + PR**

---

### Task 16: `test_66_remote_logging_toggle.py`

**Files:**
- Create: `engram/e2e/tests/test_66_remote_logging_toggle.py`

**User path covered:** Toggling remote logging on/off in settings starts/stops the periodic flush. Already partially covered by `test_16_remote_logging_pipeline.py` — focus here is on the toggle's effect (off → no flush after threshold reached).

- [ ] **Step 1: Write the test**

```python
"""Test 66: Remote logging toggle starts and stops the flush loop."""

from __future__ import annotations
import asyncio
import pytest


@pytest.mark.asyncio
async def test_disable_stops_flush(cdp_a, api_sync):
    await cdp_a.enable_remote_logging()
    await cdp_a.evaluate(
        "for (let i = 0; i < 25; i++) "
        "app.plugins.plugins['engram-vault-sync']."
        "remoteLog?.info('test66', 'tick ' + i)"
    )
    await asyncio.sleep(2)
    before = len(api_sync.list_logs(limit=200))

    await cdp_a.evaluate(
        "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
        "p.settings.remoteLogging = false; await p.saveSettings();})()",
        await_promise=True,
    )

    await cdp_a.evaluate(
        "for (let i = 0; i < 25; i++) "
        "app.plugins.plugins['engram-vault-sync']."
        "remoteLog?.info('test66', 'after-disable ' + i)"
    )
    await asyncio.sleep(2)
    after = len(api_sync.list_logs(limit=200))
    # New logs from after-disable should not have reached the server.
    new_logs = api_sync.list_logs(limit=200, query="after-disable")
    assert len(new_logs) == 0, (
        f"Disabled logging still sent {len(new_logs)} entries"
    )
```

> If `ApiClient.list_logs` does not exist, add it (similar to `search` helper). Inspect `helpers/api.py` first.

- [ ] **Step 2: Run + commit + PR**

---

### Task 17: `test_67_auth_swap.py`

**Files:**
- Create: `engram/e2e/tests/test_67_auth_swap.py`

**User path covered:** User pastes a new API key (or signs in via OAuth) replacing existing creds — vault reconnects, sync continues without restart.

- [ ] **Step 1: Write the test**

```python
"""Test 67: Swapping API key in settings re-bootstraps the engine."""

from __future__ import annotations
import asyncio
import pytest
from helpers.vault import write_note


@pytest.mark.asyncio
async def test_swap_to_invalid_key_then_back(cdp_a, sync_user, vault_a):
    original = sync_user[2]
    bogus = "INVALID-DEFINITELY-NOT-A-KEY"

    await cdp_a.evaluate(
        f"(async () => {{const p = app.plugins.plugins['engram-vault-sync']; "
        f"p.settings.apiKey = {bogus!r}; await p.saveSettings();}})()",
        await_promise=True,
    )
    path = "E2E/AuthSwap67/During.md"
    write_note(vault_a, path, "# during bogus")
    await cdp_a.trigger_full_sync()
    await asyncio.sleep(1)
    last_error = await cdp_a.get_last_error()
    assert "auth" in (last_error or "").lower() or "401" in (last_error or "")

    await cdp_a.evaluate(
        f"(async () => {{const p = app.plugins.plugins['engram-vault-sync']; "
        f"p.settings.apiKey = {original!r}; await p.saveSettings();}})()",
        await_promise=True,
    )
    await cdp_a.trigger_full_sync()
    await asyncio.sleep(1)
    # File should now reach the server.
    # (verify via api_sync if available — fixture not requested here)

    (vault_a / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 18: `test_68_token_refresh.py`

**Files:**
- Create: `engram/e2e/tests/test_68_token_refresh.py`

**User path covered:** OAuth access token expires mid-session → automatic refresh produces new token without forcing WebSocket reconnect loop.

- [ ] **Step 1: Write the test**

Use the existing OAuth pair from `test_47_oauth_websocket_live_sync.py` if it exposes a refresh-token fixture; otherwise set up via `helpers/oauth.py`.

```python
"""Test 68: Access-token refresh keeps the WebSocket alive."""

from __future__ import annotations
import asyncio
import pytest


@pytest.fixture(autouse=True)
async def _require_oauth(cdp_a):
    has_refresh = await cdp_a.evaluate(
        "Boolean(app.plugins.plugins['engram-vault-sync']."
        "settings.refreshToken)"
    )
    if not has_refresh:
        pytest.skip("Test requires OAuth auth; current instance uses API key")


@pytest.mark.asyncio
async def test_refresh_does_not_reconnect_socket(cdp_a):
    socket_id_before = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].channel?.socket?.id"
    )
    # Expire the access token in-memory.
    await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].authProvider."
        "_accessToken = 'expired'"
    )
    await cdp_a.trigger_full_sync()
    await asyncio.sleep(2)
    socket_id_after = await cdp_a.evaluate(
        "app.plugins.plugins['engram-vault-sync'].channel?.socket?.id"
    )
    assert socket_id_after == socket_id_before, (
        "Refresh must not tear down the WebSocket"
    )
```

> The auth-provider internals depend on `src/auth.ts`. Verify the field name (`_accessToken` vs `accessToken`) before committing.

- [ ] **Step 2: Run + commit + PR**

---

### Task 19: `test_69_echo_suppression.py`

**Files:**
- Create: `engram/e2e/tests/test_69_echo_suppression.py`

**User path covered:** After local push, the matching WebSocket upsert event is suppressed for 5 s so we don't double-apply our own change.

- [ ] **Step 1: Write the test**

```python
"""Test 69: Echo suppression — push then incoming WebSocket for same path
is dropped within 5 s of last push."""

from __future__ import annotations
import asyncio
import pytest
from helpers.vault import write_note


@pytest.mark.asyncio
async def test_local_echo_is_suppressed(vault_a, cdp_a, api_sync):
    path = "E2E/Echo69/Loop.md"
    write_note(vault_a, path, "# echo")
    await cdp_a.trigger_full_sync()
    await asyncio.sleep(0.2)

    # Capture pull-handler invocations.
    await cdp_a.evaluate(
        "window.__e2e_pullHandled = 0; const p = app.plugins.plugins"
        "['engram-vault-sync']; const orig = p.syncEngine."
        "applyRemoteUpsert.bind(p.syncEngine); "
        "p.syncEngine.applyRemoteUpsert = (...a) => "
        "{window.__e2e_pullHandled++; return orig(...a);}"
    )

    # Server emits an event for our own push — should be ignored.
    api_sync.broadcast_upsert(path)  # add helper if missing
    await asyncio.sleep(1)
    handled = await cdp_a.evaluate("window.__e2e_pullHandled")
    assert handled == 0, "Echo not suppressed within 5 s window"

    # After 6 s, the suppression window expires and the same broadcast applies.
    await asyncio.sleep(6)
    api_sync.broadcast_upsert(path)
    await asyncio.sleep(1)
    handled_late = await cdp_a.evaluate("window.__e2e_pullHandled")
    assert handled_late >= 1

    await cdp_a.evaluate("delete window.__e2e_pullHandled")
    (vault_a / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
```

> `api_sync.broadcast_upsert` likely does not exist. Add it as a thin POST to whatever debug/internal endpoint the backend exposes for replaying upsert events — if there is none, switch the test to drive the channel from server-side via `cdp_b`: write to vault B, let WebSocket route to A. Adjust which echo window we measure accordingly.

- [ ] **Step 2: Run + commit + PR**

---

### Task 20: `test_70_stale_file_skip.py`

**Files:**
- Create: `engram/e2e/tests/test_70_stale_file_skip.py`

**User path covered:** When local mtime is >1 h older than remote and no sync hash exists, plugin skips conflict and accepts remote as authoritative.

- [ ] **Step 1: Write the test**

```python
"""Test 70: Stale local file (>1h older than remote, no sync hash) yields
to remote without prompting a conflict."""

from __future__ import annotations
import os
import time
import pytest
from helpers.vault import write_note, read_note


@pytest.mark.asyncio
async def test_stale_local_accepts_remote(
    vault_a, vault_b, cdp_a, cdp_b
):
    path = "E2E/Stale70/Old.md"

    write_note(vault_b, path, "# remote-newer")
    await cdp_b.trigger_full_sync()

    write_note(vault_a, path, "# local-stale")
    # Force mtime to ~2 hours ago.
    two_h_ago = time.time() - 2 * 3600
    os.utime(vault_a / path, (two_h_ago, two_h_ago))
    # Clear any sync hash for this path so the staleness branch fires.
    await cdp_a.evaluate(
        "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
        "delete p.syncEngine.syncState["
        f"{path!r}]; await p.saveSettings();}})()",
        await_promise=True,
    )
    await cdp_a.trigger_full_sync()

    assert "remote-newer" in read_note(vault_a, path)
    # Cleanup
    (vault_a / path).unlink(missing_ok=True)
    (vault_b / path).unlink(missing_ok=True)
    await cdp_a.trigger_full_sync()
    await cdp_b.trigger_full_sync()
```

- [ ] **Step 2: Run + commit + PR**

---

### Task 21: `test_71_vault_limit_402.py`

**Files:**
- Create: `engram/e2e/tests/test_71_vault_limit_402.py`

**User path covered:** When `/vaults/register` returns 402, the plugin records the block and stops re-attempting on each settings save.

- [ ] **Step 1: Write the test**

```python
"""Test 71: Vault-limit 402 surfaces an Issue and disables auto-register."""

from __future__ import annotations
import pytest


@pytest.mark.asyncio
async def test_402_disables_auto_register(cdp_a):
    await cdp_a.evaluate(
        "(() => {const realFetch = window.fetch.bind(window); "
        "window.__e2e_realFetch = realFetch; "
        "window.fetch = async (url, opts) => "
        "{if (String(url).includes('/vaults/register')) "
        "return new Response('{\"error\":\"limit\"}', {status: 402}); "
        "return realFetch(url, opts);};})()"
    )
    try:
        await cdp_a.evaluate(
            "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
            "p.settings.vaultId = null; await p.saveSettings(); "
            "await p.registerVault();})()",
            await_promise=True,
        )
        blocked = await cdp_a.evaluate(
            "app.plugins.plugins['engram-vault-sync']."
            "settings.vaultLimitBlocked"
        )
        assert blocked is True
    finally:
        await cdp_a.evaluate(
            "(async () => {const p = app.plugins.plugins['engram-vault-sync']; "
            "p.settings.vaultLimitBlocked = false; await p.saveSettings();})()",
            await_promise=True,
        )
        await cdp_a.evaluate(
            "window.fetch = window.__e2e_realFetch; delete window.__e2e_realFetch"
        )
```

> Field name `vaultLimitBlocked` is a guess — confirm against `src/types.ts` and `src/main.ts` before committing. If the plugin tracks 402 via a different mechanism (issue store, in-memory flag), assert through that surface.

- [ ] **Step 2: Run + commit + PR**

---

## Self-Review Notes

- **Spec coverage:** All 19 gaps from the audit map to tasks: Search UI (2,3), ConflictModal UI (4), Sync Preview destructive (5), Sync Center (6,7), commands (8), status bar (9), ribbon (3+10), SyncProgressModal (11), SyncLogModal (12), DeviceFlowModal edges (13), settings persistence (14), problem-dir scanner (15), remote logging toggle (16), auth swap (17), token refresh (18), echo suppression (19), stale file (20), 402 vault limit (21).
- **Plugin source verification gates:** Tasks 1, 4, 7, 11, 15, 18, 21 include explicit instructions to verify selectors / field names against the plugin source. Failing this verification means the test is brittle to refactors that should have been caught.
- **Plugin-side changes welcome:** Several tasks may surface missing semantic CSS classes (`engram-issue-group`, `engram-merge-editor`, etc.). When that happens, add the class to the plugin source in the same PR as the test — don't wrap the test in fragile attribute-soup selectors.
- **Workflow reminder:** Every task gets its own branch + PR in **both** repos when plugin source changes; co-merge by linking PRs.

---

## Execution

Plan complete and saved.

Two execution options:

1. **Subagent-Driven (recommended)** — dispatch one subagent per task, review between tasks, fast iteration. 21 tasks → ~21 subagent dispatches with verify gates.

2. **Inline Execution** — execute tasks in this session using `superpowers:executing-plans`, batch checkpoints every ~3 tasks.

Which approach?
