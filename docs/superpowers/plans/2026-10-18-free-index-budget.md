# Free Index Budget Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Bound Qdrant points per Free account without blocking sync, truncating notes or making any note unsearchable.

**Architecture:** A new plan limit `index_points_cap`. Within budget a note is fully indexed (chunk points, dense + sparse). Over budget it gets one sparse-only "floor" point for the whole note: no dense vector, no Voyage call. A sweep in `ReconcileEmbeddings` keeps each account at or under its cap, most recently edited notes full first, with hysteresis.

**Tech Stack:** Elixir/Phoenix, Ecto, Oban, Qdrant REST; React SPA; Obsidian plugin (TypeScript).

**Spec:** Engram vault `50 Engineering/_Superpowers Specs/2026-10-18-qdrant-storage-and-free-index-budget-design.md`, section "Free index budget". Evidence: `engram-workspace/reports/2026-10-18-qdrant-eval/prod-measure.md`, `review-code.md`, `review-migration.md`.

## Why this ships right after Phase 0

Two Free accounts created on 2026-10-18 hold 68% of prod's 447,263 points (156,695 and 147,220). Both reached the 20M lifetime token cap within hours and keep writing sparse-only chunk points past it, so the token cap does not bound points (`prod-measure.md` 2-3). This plan depends only on storage-plan Task 1 (strict mode + telemetry). It does NOT wait for the Postgres text columns or chunker v4.

## Global Constraints

- `index_points_cap`: Free 10,000; Starter 100,000; Pro 250,000. Counted in actual `chunks` rows (today's chunker; v4 changes the count by about -19%, not enough to resize). Self-host unlimited (`limit_enforced?` false when billing is disabled, `billing.ex:453`).
- `notes_cap` stays 3,000. `lifetime_embed_token_cap` stays 20M.
- Demote above 100% of cap; promote back only below 90%.
- Sync and writes never fail because of this budget. No note is deleted or truncated.
- A floor point carries no display text: its payload text is the empty string, encrypted as today (`crypto.ex:821` encrypts `text || ""`), so `decrypt_one` accepts it before and after the storage plan's Task 5. The search snippet for a floor hit is the note title and path from `notes`.
- A floor `chunks` row has `token_count` NULL, so it never enters `avgdl` (`keyword_index/stats.ex:51` filters NULL).
- Floor and trim work is unmetered maintenance. Promotion of a note whose dense vectors we deleted is unmetered too: we never charge twice. A first-ever embed (a note that was never dense) is metered as usual.
- Cross-tenant selection runs on `Repo.maintenance()` with a zero-rows control under the app role; per-user counts run inside `Repo.with_tenant/2` (`docs/context/rls-enforcement-testing-traps.md`).
- No raw `user_id` in metrics labels. Emails: "we" voice, signed "The Engram team", no em dashes. New UI strings go through translategemma (`make i18n-core-sync`).
- Upgrades need zero operator action; existing over-budget accounts heal through the reconcile cron.
- Keep the full sparse vector on floor points (`results-exact.md`: keyword search finds exact strings).

## Review Focus

1. A floor note searched by a term from its LAST section matches, and ranks above an unrelated full chunk that shares no rare term (proves no truncation and no length-norm burial). Task 2.
2. Two embed jobs near the cap at once: overshoot is bounded by one note's chunks; the next sweep corrects it. Task 3.
3. A Starter account over its cap must not re-index forever: floor notes are never reselected by the dense-missing reconcile. Task 2.
4. Demoting 147k points must not wedge Qdrant: batches pause while the collection is red, and deletes go first. Task 4.
5. Upgrading Free to Starter promotes every floor note over successive sweeps, newest first, without charging the user for vectors we deleted. Task 4.

---

### Task 1: `index_points_cap` limit key

**Files:**
- Modify: `lib/engram/billing/limit_keys.ex:19-83`
- Test: `test/engram/billing/limit_keys_test.exs`

**Interfaces:** `LimitKeys.default_for(:index_points_cap, :free) == 10_000`, `:starter == 100_000`, `:pro == 250_000`, `type == :integer`.

- [ ] **Step 1: Failing test** for the three defaults and the type.
- [ ] **Step 2: Run** `mise exec -- mix test test/engram/billing/limit_keys_test.exs`. Expected: FAIL.
- [ ] **Step 3: Add the key** with a comment pointing at the spec.
- [ ] **Step 4: Run.** Expected: PASS (the dead-entry test passes once Task 3 reads the key; land Tasks 1-3 in one PR).
- [ ] **Step 5: Commit** `feat(billing): index_points_cap limit key`.

### Task 2: Floor index plan

**Files:**
- Create: migration `<ts>_add_notes_index_tier.exs` (`phase/expand`: `notes.index_tier text NULL`; NULL = full, `"floor"` = never had dense, `"floor_paid"` = had dense before demotion)
- Modify: `lib/engram/indexing.ex:144` (`prepare_index`), `:752-765` (`plan_within_budget`), `lib/engram/notes/note.ex`, `lib/engram/keyword_index/` (floor length norm), `lib/engram/workers/reconcile_embeddings.ex:130` (exclude floor notes from the dense-missing selector)
- Test: `test/engram/indexing_floor_test.exs`

**Interfaces:**
- `Indexing.floor_plan(note, chunks) :: plan`: ONE entry, sparse vector over the union of every chunk's keyword terms, `dense: nil`, position 0; one `chunks` row with `token_count: nil`. Document length for BM25 is `min(len, avgdl)`, so a whole-note vector is not buried by length normalisation.
- Consumes `purge_before_rebuild` / `drop_stale_points` (`indexing.ex:356-366`) to delete the note's previous points.
- ReconcileEmbeddings never selects a note with `index_tier` set for the dense-missing pass (today a floor stamp of `dense_indexed_hash` nil, `embed_note.ex:636-642`, would reselect it every 24 h for Free and every 5 min for paid users).

- [ ] **Step 1: Failing tests:**
  - a 3-section note indexed as floor writes 1 row and 1 point with no `dense`; zero embedder calls; `lifetime_embed_tokens` unchanged
  - `sparse_search` for a term only in section 3 returns the note
  - the floor note outranks an unrelated full chunk on a term unique to the floor note
  - the floor row's `token_count` is NULL and `avgdl` for the vault is unchanged
  - two reconcile ticks after flooring enqueue nothing for that note, on Free and on Starter
  - the floor payload decrypts through today's `decrypt_one` with empty text
- [ ] **Step 2: Run** `mise exec -- mix test test/engram/indexing_floor_test.exs`. Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the new file plus `test/engram/indexing*`, `test/engram/workers/reconcile*`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(indexing): sparse-only floor index for over-budget notes`.

### Task 3: Budget check before reserving tokens

**Files:**
- Modify: `lib/engram/indexing.ex:752-765` (decide full vs floor BEFORE `reserve_tokens`), `lib/engram/workers/embed_note.ex:283` (`budget_opts`)
- Test: `test/engram/workers/embed_note_points_budget_test.exs`

**Interfaces:** `Indexing.points_budget_ok?(user, note_id, planned_points) :: boolean()`: true when billing is disabled or the cap is nil; else `count(chunks of user) - count(chunks of note) + planned_points <= cap`, inside `Repo.with_tenant/2`, on `idx_chunks_user` (`structure.sql:993`).

- [ ] **Step 1: Failing tests:**
  - Free at 9,990 indexing a 5-chunk note: full; at 9,998: floor, `index_tier = "floor"`
  - the floor path reserves zero tokens (no reservation to release)
  - billing disabled at 100,000: full; Starter at 50,000: full
  - REST and socket creates over the cap both succeed
  - the count without a tenant set is 0 (control), and the function sets the tenant itself
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the new file plus `test/engram/workers/embed_note*`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(embed): enforce index points budget on free`.

### Task 4: Trim and promote sweep

**Files:**
- Modify: `lib/engram/workers/reconcile_embeddings.ex:66`
- Test: `test/engram/workers/reconcile_points_budget_test.exs`

**Interfaces:**
- `ReconcileEmbeddings.budget_sweep(limit_users :: pos_integer()) :: {:ok, %{demoted: n, promoted: n}}`. Selection on `Repo.maintenance()`: at most 20 users per tick with chunk count > cap, or with floor notes and room below 90%.
- Demote: rank full notes by `updated_at` desc, running sum of chunk counts; every note past the cap gets `"floor_paid"` if it had dense (`dense_indexed_hash == embed_hash`), else `"floor"`, and is enqueued at backfill priority. At most 200 notes per user per tick. A tick does nothing while `Qdrant.collection_health/1` is `:red`.
- Promote: under 90%, newest floor notes first, while the projected count stays under 90%. `"floor_paid"` promotes as maintenance (unmetered); `"floor"` promotes metered and respects the token cap. `ponytail:` ceiling: at most 2,000 unmetered promoted points per user per day, so delete-and-promote cycles cannot spend unbounded Voyage.

- [ ] **Step 1: Failing tests:**
  - Free with 12,000 points over 40 notes demotes oldest-first to at or under 10,000; note count unchanged; a second sweep does nothing
  - 1,000 over-cap notes demote across 5 ticks (200 per tick); a red collection pauses the tick
  - a floor user at 8,500 promotes newest floor notes while staying under 9,000; at 9,500 nothing promotes
  - a `"floor_paid"` promotion leaves `lifetime_embed_tokens` unchanged; a `"floor"` promotion meters
  - an upgraded user (cap nil) promotes all floor notes over successive sweeps
  - a chunker version bump keeps floor notes on floor, unmetered
  - selection without the maintenance pool returns 0 users (control)
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the new file plus `test/engram/workers/reconcile*`. Expected: PASS.
- [ ] **Step 5: Commit** `feat(reconcile): keep free accounts within index budget`.
- [ ] **Step 6: Pre-merge check:** run the demote selection read-only against prod with the audit role (`prod-measure.md` method) and list affected users with resolved plan. Expected: the 4 users over 10k, all Free. Comped 100%-off subscriptions resolve as paid tiers in the DB and are not demoted.

Disk note: demotion deletes about 280k points, but Qdrant returns that disk only when vacuum rewrites a segment, which needs free space (`review-qdrant.md` #2, #3). Strict mode (storage Task 1) keeps the cluster writable meanwhile; the real reclaim comes with the storage plan's v2 copy.

### Task 5: Usage API, UI copy, search label

**Files:**
- Modify: `lib/engram_web/controllers/billing_controller.ex:52` (`index_points: %{used, limit}`), `lib/engram/search.ex` (`match: "keyword"` on floor hits in BOTH the grouped path, `collapse_to_notes` at `:668`, and the ungrouped path), `lib/engram_web/schemas/search.ex` (`match` field) and `openapi.json` (regen; CI gate `verify.yml:2814`), frontend usage panel + search hit component, plugin `src/plan-usage.ts` (usage rows; `plan-state.ts:37` only parses capabilities)
- Test: `test/engram_web/controllers/billing_controller_test.exs`, `test/engram/search_floor_label_test.exs`, frontend usage-row unit test, plugin `plan-usage` unit test

**Interfaces:** `GET /api/billing/usage` adds `"index_points": {"used": 10000, "limit": 10000}` (`limit: null` when unlimited). Floor hits carry `"match": "keyword"` and an empty snippet; the UI shows the title.

Copy (source English, translated by translategemma):
- Usage row: "Detailed search: {used} of {limit} passages. Older notes are still found by keyword."
- Search label: "Keyword match"
- No toast anywhere: nothing failed.

- [ ] **Step 1: Failing tests** for the API shape (Free and unlimited), the label on grouped and ungrouped hits, the usage row both cases, the plugin row.
- [ ] **Step 2: Run** backend, `cd frontend && bun test`, `cd plugin && bun test`. Expected: FAIL.
- [ ] **Step 3: Implement**, run `make i18n-core-sync`, regenerate `openapi.json`.
- [ ] **Step 4: Run.** Expected: PASS. Grep `e2e/tests/` and `frontend/e2e/` for usage-panel selectors before changing markup.
- [ ] **Step 5: Commit** per repo: `feat(billing): expose index points usage`, `feat(web): index budget usage row`, `feat(plugin): index budget plan row`.

### Task 6: Metrics and one-time notice

**Files:**
- Create: migration `<ts>_add_usage_meters_index_notice.exs` (`phase/expand`: `usage_meters.index_notice_sent_at timestamptz NULL`), email template on the legal-notice email machinery (per-user language)
- Modify: `lib/engram/prom_ex/indexing.ex` (gauge `engram_prom_ex_index_points_users{bucket}` with buckets `0`, `lt_1k`, `lt_10k`, `ge_10k`, computed on `Repo.maintenance()`; counter `engram_prom_ex_index_floor_total`)
- Test: `test/engram/prom_ex/indexing_budget_test.exs` (with a zero-rows control), email key test (`email-keys.test.ts` gate)

Email copy:

> Subject: A change to search on your Engram vault
>
> Hi, we are changing how search works for large vaults on the Free plan. Your most recently edited notes keep detailed search, which finds the exact passage you need. Older notes are still searchable by keyword, they just match as whole notes. Nothing is deleted and sync is not affected. Upgrading restores detailed search on every note.
>
> The Engram team

- [ ] **Step 1: Failing tests** for gauge buckets from seeded users, the control, the email in two languages, and send-once (a second demote does not re-send).
- [ ] **Step 2: Run.** Expected: FAIL.
- [ ] **Step 3: Implement.** The first demote of an account sends the notice and sets `index_notice_sent_at`; no operator.
- [ ] **Step 4: Run.** Expected: PASS.
- [ ] **Step 5: Commit** `feat(billing): index budget metrics and notice`.

---

## Sizing (spec "Per-point budget")

- Today: 9.8 KB disk per point measured (2.57 GiB / 281,379 on 10-18 morning).
- After the storage plan's v2 (1024 f16 on disk, no text, sparse f32 values): about 4.1 KB per point (dense 2,048 + binary 128 + sparse about 1,450 + graph, ids and indexes about 500). RAM about 0.4 KB per point.
- Floor points: one per over-budget note, sparse union of the note, about 2-10 KB each. A capped whale is about 10,000 x 4.1 KB + about 1,300 floor points, roughly 50-55 MB.
- Today's 291 users capped: about 150k points. At that mix 1,000 users is about 0.5M points, 2-3 GB, 30-45% of the usable 8 GiB tier. The range is driven by how many whales sign up; the cap bounds each one.

## Rejected findings

| Finding | Reason |
|---|---|
| Gate Task 3 on chunker v4 (`review-migration` #24) | The cap counts real rows at whatever chunker version is live; v4 moves the count only -19% |
| Keep demoted vectors cold for free promotion (`review-migration` #25, C1) | Needs the S3 vector store (epic #609 follow-up); promotion of `"floor_paid"` is unmetered instead |
