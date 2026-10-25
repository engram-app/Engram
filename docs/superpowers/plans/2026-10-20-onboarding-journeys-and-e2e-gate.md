# Onboarding Journeys and e2e Gate (Canary Phase 1) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prove the three onboarding paths end to end in CI, make the e2e-clerk failure classes that remain deterministic, make scenarios self-describing so the future canary discovers them, then make e2e-clerk a blocking check.

**Architecture:** Browser journeys are Playwright specs in `frontend/e2e/` (clerk project). The plugin-first journey is a pytest test in `e2e/tests/` that drives real Obsidian over CDP and a Python Playwright Chromium for the browser leg. Scenario metadata uses each runner's native mechanism (Playwright test tags/annotations/`test.step`, pytest markers plus a `timed_step` context manager) and one discovery script turns both into JSON.

**Tech Stack:** Playwright 1.64 (TS) + `@clerk/testing` + `@modelcontextprotocol/sdk` 1.32; pytest 9 + Python `playwright` + the CDP harness in `e2e/helpers/`; GitHub Actions `verify.yml`.

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-20-staging-canary-platform-design.md` (sections 1 and 6, build-order steps 1 and 2).

## Global Constraints

- Branch `test/onboarding-journeys`, PR #2102 (one PR for this whole plan except Task 7, which is its own PR after the watch window).
- Never run app stacks, suites, `tsc`, mix or builds on the dev VM. Verify on CI. Iterate with a `[e2e: browser/<pattern>]` or `[e2e: clerk/<pattern>]` tag in the HEAD commit message; the final push before merge has no tag (a targeted run is not mergeable).
- Allowed locally: `e2e/unit` pytest (`cd e2e/unit && timeout 120 nice python3 -m pytest <file>`), `frontend/node_modules/.bin/biome check --write <files>`, `ruff` on changed Python.
- Every brand-new Clerk user a test creates is deleted by that test in teardown (helpers `createUnonboardedUser`/`deleteClerkUser` in `frontend/e2e/clerk-helpers.ts`, `ClerkClient.create_user`/`delete_user` in `e2e/helpers/clerk.py`).
- Specs must be target-agnostic where marked canary: no `db-cleanup`, no `docker exec`, no direct Postgres. Base URLs come from env.
- Signed conventional commits ending with the Co-Authored-By and Claude-Session lines. No em dashes in prose.
- Never loosen, skip or narrow an existing test to get green.

## Review Focus

- **A retry after a half-finished journey:** Playwright retries once; each attempt must create its own fresh user (per-attempt `beforeEach`, never `beforeAll`). Covered in Tasks 2 and 3 by structure; Task 2's spec asserts the user lands in `/onboard`, which fails on a reused user.
- **Clerk quota exhaustion mid-suite:** a 400/422 "user limit"/quota response must surface as `ClerkQuotaError` with the word "Clerk quota" in the message, not a generic HTTPError. Test in Task 5.
- **Embed job discarded:** the Qdrant wait must fail fast with the job's errors when the EmbedNote job is `discarded`/`cancelled`, not spin to timeout. Test in Task 4.
- **Embed job slow but alive:** under a contended Ollama the job sits `available`/`executing` past 90s; the wait must keep going while the job is alive (up to the hard cap). Test in Task 4.
- **Untagged or half-described scenario:** a `@canary` test missing cadence or targets must fail discovery loudly. Test in Task 1.

---

### Task 1: Scenario manifest and discovery

**Files:**
- Create: `e2e/scripts/list_scenarios.py`
- Create: `e2e/helpers/scenario.py`
- Modify: `e2e/pytest.ini` (register `canary` marker)
- Modify: `frontend/e2e/mcp-first-journey.spec.ts` (add tag, annotations, `test.step`)
- Test: `e2e/unit/test_list_scenarios.py`

**Interfaces:**
- Produces (pytest): marker `@pytest.mark.canary(cadence: str, targets: list[str])`; context manager `timed_step(name: str)` in `e2e/helpers/scenario.py` that appends `{"step": name, "seconds": float, "ok": bool}` to the list at `request.node.user_properties["steps"]` (accessed via a `scenario_steps` fixture) so it lands in junit XML properties.
- Produces (Playwright): a canary scenario is a `test(title, { tag: ["@canary"], annotation: [{ type: "cadence", description }, { type: "targets", description: "ci,staging" }] }, ...)` whose timed steps are `await test.step("<name>", ...)`.
- Produces: `python3 e2e/scripts/list_scenarios.py --playwright-json <file> --pytest-collect <file>` prints a JSON array of `{"name", "runner": "playwright"|"pytest", "file", "cadence", "targets": [..], "tags": [..]}`; exits 1 naming the test if a `@canary`/`canary` scenario lacks `cadence` or `targets`. Allowed cadences: `10m`, `hourly`, `2h`, `daily`. Allowed targets: `ci`, `staging`, `staging-limits`, `prod`.
- Input formats: Playwright `--list --reporter=json` output; pytest `--collect-only -q -m canary` plus a conftest hook that writes `[{nodeid, cadence, targets}]` to the path in env `SCENARIO_COLLECT_OUT`.

- [ ] **Step 1: Write failing tests** in `e2e/unit/test_list_scenarios.py`: `test_playwright_canary_scenario_listed` (fixture JSON with one `@canary` test carrying cadence `hourly` and targets `ci,staging` yields one entry with those values); `test_untagged_tests_ignored`; `test_missing_cadence_fails_naming_the_test` (exit code 1, stderr contains the test title); `test_unknown_target_fails`; `test_pytest_collect_entries_merged`.
- [ ] **Step 2: Run** `cd e2e/unit && timeout 120 nice python3 -m pytest test_list_scenarios.py -v`. Expected: FAIL (module missing).
- [ ] **Step 3: Implement** `list_scenarios.py` (stdlib only: `json`, `argparse`, `sys`), `scenario.py` (`timed_step` with `time.monotonic()`, records `ok=False` and re-raises on exception), the conftest hook (`pytest_collection_modifyitems` writing marker kwargs when `SCENARIO_COLLECT_OUT` is set), and the `canary` marker in `pytest.ini`.
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Describe the MCP-first spec:** tag `@canary`, cadence `hourly`, targets `ci,staging`; wrap its four phases in `test.step`: `discover-and-register`, `sign-in-onboard-approve`, `token-exchange-and-tools`, `note-visible-in-web`.
- [ ] **Step 6: Biome + ruff** on changed files; commit `feat(e2e): self-describing canary scenarios`.

### Task 2: Website-first journey

**Files:**
- Create: `frontend/e2e/web-first-journey.spec.ts`
- Modify: `frontend/playwright.config.ts` (add `web-first-journey` to the clerk project's `testMatch` alternation)

**Interfaces:**
- Consumes: `createUnonboardedUser(prefix)`, `deleteClerkUser(id)`, `clerkSignIn(page, email, landOn)` from `clerk-helpers.ts`; Task 1 tag/annotation shape.

- [ ] **Step 1: Write the spec** `test("sign up on the web, onboard, write a first note", { tag: ["@canary"], annotation: [cadence hourly, targets ci,staging] })` with per-attempt user `createUnonboardedUser("e2e-browser-webfirst")`. Steps (`test.step` names in quotes):
  - `"sign-in"`: `clerkSignIn(page, email, "/")`; expect URL `/onboard/agreement`.
  - `"terms"`: check the agree box, Continue; expect `/onboard/heard`.
  - `"heard"`: pick any option (read `frontend/src/onboarding/heard-page.tsx` for the control), Continue; expect `/onboard/vault`.
  - `"vault"`: fill "Vault name" with `Journey Vault`, submit (read `onboard-vault-page.tsx` for the button label); expect the app shell (`navigation` "App navigation") visible.
  - `"first-note"`: create a note named `First note` with body `Hello from the web` through the UI (read the tree/new-note control in the SPA), wait for the save indicator.
  - `"note-persists"`: reload; the note is in the tree and opening it shows the body.
- [ ] **Step 2: Push** with `[e2e: browser/web-first-journey]`; read the e2e-browser result. Expected: PASS. Fix the spec against real labels until it passes; never relax an assertion.
- [ ] **Step 3: Biome; commit** `test(e2e): prove the website-first onboarding journey`.

### Task 3: Unskip the FTUX specs

**Files:**
- Modify: `frontend/e2e/onboarding-ftux.spec.ts`

**Interfaces:**
- Consumes: `createUnonboardedUser`, `deleteClerkUser`, `clerkSignIn`; the web-first wizard walk from Task 2 (extract it to `clerk-helpers.ts` as `export async function completeWebOnboarding(page: Page, vaultName: string): Promise<void>` and use it in both specs).

- [ ] **Step 1:** Replace the shared `state.email` user with a per-test fresh user plus `completeWebOnboarding` (or stop before the vault step where the test asserts the vault modal). Delete every `test.skip(true, ...)` whose reason is "wizard not pre-completed" or "user already has a vault": a fresh user makes both conditions false. The device-link checklist test keeps its skip only until Task 6's helper exists; then wire it to Task 6's `start_device_flow` equivalent over HTTP (`POST /api/auth/device/start`, authorize in the page, `POST /api/auth/device/token`) and unskip it.
- [ ] **Step 2: Push** with `[e2e: browser/onboarding-ftux]`. Expected: 5 of 5 PASS, 0 skipped.
- [ ] **Step 3: Commit** `test(e2e): run the FTUX specs on fresh users instead of skipping`.

### Task 4: Qdrant index wait follows the embed job

**Files:**
- Modify: `e2e/helpers/crypto_probe.py` (`wait_for_qdrant_indexed`)
- Test: `e2e/unit/test_qdrant_wait.py`

**Interfaces:**
- Produces: `wait_for_qdrant_indexed(vault_id: str, path_hmac_b64: str, path: str | None = None, timeout: float = 30.0, hard_cap: float = 300.0) -> None`. Same signature for callers; `timeout` now means "no progress for this long".
- New internal: `_embed_job_state(vault_id: str, path_hmac_b64: str) -> tuple[str | None, str]` returning `(state, errors_text)` from `oban_jobs` (`worker = 'Engram.Workers.EmbedNote'`, `args->>'note_id'` = the note whose `vault_id` and `path_hmac = decode(<b64>, 'base64')` match, newest job first) via the same `docker exec psql` pattern as `latest_note_path_hmac`.

Rule: return when the point exists. Raise immediately (`RuntimeError` with state and errors) when the job state is `discarded` or `cancelled`. Keep waiting while the state is `available`, `scheduled`, `executing` or `retryable`, up to `hard_cap`. When the state is `completed` (or there is no job) and no point appears within `timeout`, raise `TimeoutError` with the last seen state.

- [ ] **Step 1: Write failing tests** with the Qdrant HTTP call and `_embed_job_state` monkeypatched: `test_returns_when_point_appears`; `test_discarded_job_fails_fast_with_errors` (raises within one poll, message contains `discarded` and the error text); `test_alive_job_outlives_timeout` (job `executing` for 3 polls past `timeout`, then point appears: returns); `test_hard_cap_bounds_an_alive_job`; `test_completed_without_point_times_out`. Patch `time.sleep`/`time.monotonic` with a fake clock.
- [ ] **Step 2: Run** `cd e2e/unit && timeout 120 nice python3 -m pytest test_qdrant_wait.py -v`. Expected: FAIL.
- [ ] **Step 3: Implement.** Callers using `timeout=90` change to the default (`test_32`, `test_67`, `test_77`).
- [ ] **Step 4: Run tests.** Expected: PASS.
- [ ] **Step 5: Commit** `fix(e2e): Qdrant index wait follows the embed job, not a clock`.

### Task 5: Clerk quota errors are named

**Files:**
- Modify: `e2e/helpers/clerk.py`
- Test: `e2e/unit/test_clerk_retry.py` (extend)

**Interfaces:**
- Produces: `class ClerkQuotaError(RuntimeError)` in `e2e/helpers/clerk.py`. `ClerkClient.create_user` raises it when the final response is 429, or 400/422 whose body's `errors[].code` is a quota/limit code (read Clerk's error codes from the failing runs in `/tmp/claude-1000/-home-open-claw-documents-code-projects-engram-workspace/64bd969c-f775-400f-be0f-e932400d4bb1/scratchpad/logs/` if present, else match codes containing `quota` or `limit`). Message starts with `Clerk quota:` and includes status and code. Other 4xx keep raising `HTTPError`.
- The existing urllib3 `Retry` already retries 429/5xx; 400/422 quota responses are not retried (retrying a full cap cannot help) but are named.

- [ ] **Step 1: Write failing tests** with a stub session: `test_429_after_retries_is_clerk_quota`; `test_422_user_limit_is_clerk_quota`; `test_422_identifier_taken_still_reuses_user` (existing behavior kept); `test_other_400_is_http_error`.
- [ ] **Step 2: Run** them. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `fix(e2e): name Clerk quota failures`.

### Task 6: Plugin-first journey (real Obsidian)

**Files:**
- Create: `e2e/tests/test_105_plugin_first_journey.py`
- Create: `e2e/helpers/clerk_browser.py`
- Test: `e2e/unit/test_clerk_browser.py`

**Interfaces:**
- Consumes: `ClerkClient` (Task 5), `timed_step` and `@pytest.mark.canary` (Task 1), CDP fixtures from `e2e/conftest.py` (use a fresh, unlinked instance fixture; read `conftest.py` for the one that yields an Obsidian with the plugin installed but no credentials, or add `fresh_unlinked_instance` there following `fresh_instance_pair`).
- Produces: `clerk_sign_in_url(client: ClerkClient, user_id: str, app_base: str, redirect_path: str) -> str` in `clerk_browser.py`: creates a Clerk sign-in token (`POST /sign_in_tokens` with `user_id`, `expires_in_seconds=300`) and returns `"{app_base}/sign-in?__clerk_ticket={token}&redirect_url={quoted app_base+redirect_path}"`. Unit test checks URL shape with a stub client.

Journey (`@pytest.mark.canary(cadence="hourly", targets=["ci", "staging"])`, each bullet a `timed_step`):
- `seed-local-vault`: write 20 notes (nested folders, one unicode name, one with frontmatter) and one PNG into the fresh instance's vault on disk before linking.
- `start-link-from-plugin`: over CDP, replace `window.open` with a recorder, then call the plugin's device-flow start (`app.plugins.plugins["engram-vault-sync"]`; read `src/settings.ts:296` `startDeviceFlow` in the plugin repo for the reachable entry point). Read the recorded URL: it is `/link?user_code=...` on the SPA.
- `browser-sign-in-and-onboard`: brand-new user via `ClerkClient.create_user` (no onboarding), Python Playwright Chromium opens `clerk_sign_in_url(..., redirect_path=<recorded /link path>)`. Complete the terms step if shown. On `/link`, the vault picker suggests the plugin's vault name; confirm.
- `plugin-receives-token`: the plugin's device-flow poll completes (poll the plugin's settings/credential state over CDP until linked, 60s).
- `first-sync`: trigger full sync (`cdp.trigger_full_sync()`); wait for quiescence (`await_quiescent`).
- `server-has-vault`: via the user's API key or the plugin's token, list notes: all 20 paths present, the attachment present, frontmatter note content byte-equal.
- Teardown: delete the Clerk user (and with it the account via `DELETE /api/me` using the plugin's token).

- [ ] **Step 1: Write** `test_clerk_browser.py` (URL shape, quoting); run it: FAIL; implement `clerk_browser.py`; run: PASS.
- [ ] **Step 2: Write** `test_105_plugin_first_journey.py`.
- [ ] **Step 3: Push** with `[e2e: clerk/test_105]`. Expected: PASS. Iterate against real behavior; never relax the server-side assertions.
- [ ] **Step 4: Commit** `test(e2e): prove the plugin-first onboarding journey with real Obsidian`.

### Task 7: e2e-clerk becomes blocking (separate PR, after the watch)

**Precondition:** after Tasks 4-5 are on main, 48h of e2e-clerk on main, the 06:00 schedule and plugin dispatch runs fail under 3% with no test_77 or test_101 class failures. Measure with `gh run list -R engram-app/Engram --workflow verify.yml --created ">=<date>" --json databaseId,event,conclusion` then each run's e2e-clerk job conclusion.

**Files:**
- Modify: `.github/workflows/verify.yml` `ci` job (`needs` at line ~4764 and the check script)

- [ ] **Step 1:** Add `e2e-clerk` to `ci.needs`; in "Check required jobs", fail unless its result is `success` or `skipped`. Update the comment block that says e2e-clerk is report-only, citing this plan.
- [ ] **Step 2: Push** a branch with no `[e2e:]` tag; confirm `ci` waits for e2e-clerk and goes green.
- [ ] **Step 3:** Update `docs/context/ci-pipeline-gating.md` (e2e-clerk gates PRs via `ci`).
- [ ] **Step 4: Commit** `ci: e2e-clerk gates merges through the ci aggregate`; open its own PR.

### Task 8: Finish PR #2102

- [ ] **Step 1:** Push the branch with NO `[e2e:]` tag (full suite). Expected: all checks green, including e2e-browser with the three journey specs and the FTUX specs, and e2e-clerk with test_105.
- [ ] **Step 2:** Mark PR #2102 ready; update its body with what each journey proves.
