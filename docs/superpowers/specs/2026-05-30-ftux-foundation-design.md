# First-Time User Experience (FTUX) — Foundation

## Context

After a new user completes the existing onboarding wizard (agreement → billing), the web app drops them on an empty dashboard with no guidance. There is no prompt to create their first vault, no nudge toward installing the Obsidian plugin, no tour of the app surface. The onboarding wizard solves the legal/payment gate but stops short of helping the user do anything.

This change adds the foundation for an FTUX layer:

1. A **persistent onboarding actions table** in Postgres, tracking discrete user-completed steps (first vault created, plugin connected, AI connected, tour decisions). New actions append over time without schema churn.
2. A **dashboard-level shell** that auto-opens two modals on first load: an optional "Take a tour?" offer and a blocking "Create your first vault" modal.
3. A **driver.js-powered guided tour** that renders against a static demo fixture (no real backend state), walking through sidebar / folders / editor / search / settings.
4. A **persistent checklist widget** bottom-right, dismissible per session, that tracks remaining FTUX items (install plugin, take tour, etc.) and disappears once everything is done.

This is intentionally scoped to the foundation. The connections page is in flight in a parallel worktree; a tour step pointing at it will be added when that page lands. AI connection tracking ships as a stub action ready to be set later.

## Scope

**In scope (this PR/spec):**
- New `onboarding_actions` table + Ecto schema + context + migration with backfill
- Extend `GET /api/onboarding/status` payload (no new round-trip)
- New `POST /api/onboarding/actions` endpoint (idempotent)
- Hooks in `Vaults.create_vault/2` and device-link OAuth completion to record actions
- React: tour-offer modal, create-first-vault modal, checklist widget, driver.js controller, demo-vault provider, demo fixture JSON
- Tour step content for the foundation app surface (vault/folder/editor/search/settings)
- Backend + E2E test coverage

**Out of scope (deferred):**
- Connections page tour step (added when connections page lands; one-line insertion in `steps.ts`)
- AI connection real wiring (stub action only)
- Mobile (<768px) tour — checklist still works; tour offer suppressed on small viewports
- Multi-tab tour coordination (BroadcastChannel) — defer unless QA flags

## User flow

```
sign up (Clerk)
  └─ existing onboarding wizard
       ├─ /onboard/agreement
       └─ /onboard/billing
land on dashboard /
  ├─ Tour-Offer modal               ← NEW (auto-open on every dashboard mount until terminal decision recorded)
  │   ├─ "Take tour"  → swap view to demo fixture → driver.js tour → exit → demo unmounts
  │   └─ "Skip"       → record action → close
  ├─ Create-First-Vault modal       ← NEW (auto-open after tour modal closes; only if vault_count == 0)
  │   └─ name input → POST /api/vaults → close → dashboard now real
  └─ Checklist widget bottom-right  ← NEW (persistent, dismissible per session)
       ├─ ✅ Create first vault
       ├─ ☐ Install Obsidian plugin   → expands to device-link instructions
       ├─ ☐ (stub) Connect AI         → grayed "coming soon" until connections lands
       └─ ☐ Take the tour             (shown only if user skipped initially)
```

Rules:
- Vault modal blocks (no X, ESC ignored, click-outside ignored) — vault is required for app use.
- Tour modal non-blocking (X + Skip button).
- Checklist hides when all required actions done. Dismiss = collapse to FAB, not delete.
- Tour-offer modal re-fires until user records EITHER `tour_offered_skipped` OR `tour_completed`. Recording only `tour_offered_taken` (user took tour but didn't finish) = re-offer next session.

## Data model

New table, insert-only event log:

```elixir
create table(:onboarding_actions, primary_key: false) do
  add :id,         :uuid,    primary_key: true
  add :user_id,    references(:users, type: :uuid, on_delete: :delete_all), null: false
  add :action,     :string,  null: false   # enum-validated in changeset
  add :metadata,   :map,     default: %{}  # jsonb, future-proof
  add :inserted_at, :utc_datetime_usec, null: false
end

create unique_index(:onboarding_actions, [:user_id, :action])
create index(:onboarding_actions, [:user_id])
```

Standard per-user RLS policy (mirror existing user-scoped tables).

Action enum (validated in `Onboarding.Action` changeset):

- `tour_offered_taken`
- `tour_offered_skipped`
- `tour_completed`
- `first_vault_created`
- `plugin_connected`
- `ai_connected` *(stub, set when connections wires it)*

**Backfill in migration:** for every existing user with `count(vaults) > 0`, insert a `first_vault_created` row. Single transaction, idempotent via unique index. Test on staging snapshot before prod.

## API surface

**Extend existing endpoint** (no new round-trip):

```
GET /api/onboarding/status
→ {
    next_step: "done" | "agreement" | "billing",
    actions:   ["first_vault_created", "tour_offered_skipped", ...],
    vault_count: 2
  }
```

Server-side resolver reads actions set + vault_count in one SELECT with subquery COUNT — no N+1. Frontend reads this once on app mount via existing `useOnboardingStatus()` TanStack query; tour modal, vault modal, and checklist all derive their state from it.

**New endpoint** (low-frequency, user-triggered writes only):

```
POST /api/onboarding/actions
body: { action: "tour_offered_skipped" }
→ 200 always (idempotent via unique index)
```

After successful POST, frontend manually invalidates the bootstrap query (or applies optimistic update).

## Index.html pattern (not used here)

`EngramWeb.SpaController` injects `<script>window.__ENGRAM_CONFIG__=...</script>` for instance-level config (auth provider, Clerk key, billing flag, bootstrap_pending, registration_mode). That injection runs before Clerk hydrates the session — Phoenix has no authenticated user at SPA-HTML-serve time, so per-user onboarding state cannot ride that channel. Authenticated fetch is required; bundling into the existing status endpoint is the round-trip-minimization.

## Demo fixture

Static JSON at `public/demo-vault.json`, ~10KB:
- 1 vault: "Demo Vault"
- 3 folders: "Welcome", "Examples", "Reference"
- ~12 sample notes with full markdown features (wikilinks within fixture set, callouts, code, math, mermaid)
- Wikilinks resolve only within the fixture; unresolved bracketed links render plainly via existing markdown renderer behavior

**Loading:** lazy-fetched ONLY when user clicks "Take tour" — never bundled into main JS. Browser caches indefinitely. Saves bytes for the (likely majority) skip-tour users.

## Component layout

### Frontend (`frontend/src/onboarding/`)

```
onboarding/
├─ checklist-widget.tsx           ← NEW
├─ tour-offer-modal.tsx           ← NEW (auto-opens on dashboard mount)
├─ create-first-vault-modal.tsx   ← NEW (blocking, reuses VaultCreateForm)
├─ use-onboarding-actions.ts      ← NEW (list + record hook, wraps TanStack mutation)
└─ tour/
   ├─ controller.tsx              ← NEW (driver.js lifecycle wrapper)
   ├─ steps.ts                    ← NEW (DriveStep array)
   └─ demo-vault-provider.tsx     ← NEW (React context — swaps API data for fixture during tour)
```

**Static asset:** `frontend/public/demo-vault.json` ← NEW

**Existing files touched (frontend):**
- `frontend/src/router.tsx` — wrap Dashboard route in `<OnboardingShell>` (mounts modals + checklist)
- `frontend/src/viewer/dashboard.tsx` + sidebar/folder/search components — add `data-tour="..."` anchor attrs
- `frontend/src/settings/vaults-page.tsx` — extract inline create-vault form into shared `<VaultCreateForm>` for modal reuse

**Library:** `bun add driver.js` (~5KB gz, MIT)

### Backend (`lib/engram/onboarding/`)

```
onboarding.ex            ← NEW (context: list_actions/1, record_action/2 idempotent)
onboarding/action.ex     ← NEW (Ecto schema + enum-validated changeset)
```

**Migration:** `priv/repo/migrations/<ts>_create_onboarding_actions.exs` ← NEW (table + RLS + backfill)

**Existing files touched (backend):**
- `lib/engram_web/controllers/onboarding_controller.ex` — extend `status/2` JSON; add `record/2` POST handler
- `lib/engram_web/router.ex` — wire `POST /api/onboarding/actions` on vault-scoped pipeline
- `lib/engram/vaults.ex` — after successful `create_vault/2`, call `Onboarding.record_action(user_id, :first_vault_created)` (no-op on duplicate)
- `lib/engram_web/controllers/oauth/device_controller.ex` (or device-link completion site) — record `:plugin_connected`

## Tour content

Five highlight steps + one final overlay. Demo fixture provides anchor targets.

```ts
// tour/steps.ts
export const tourSteps: DriveStep[] = [
  { element: '[data-tour="sidebar-vaults"]', popover: {
      title: 'Your vaults',
      description: 'A vault is a collection of notes. You can have many. Right now you’re looking at a demo.',
      side: 'right', align: 'start' } },
  { element: '[data-tour="folder-tree"]', popover: {
      title: 'Folders mirror your filesystem',
      description: 'The folder structure here matches what lives in your Obsidian vault on disk.',
      side: 'right' } },
  { element: '[data-tour="note-viewer"]', popover: {
      title: 'Read and edit anywhere',
      description: 'Click any note to view it. Full Obsidian-style markdown — wikilinks, callouts, math, mermaid.',
      side: 'left' } },
  { element: '[data-tour="search"]', popover: {
      title: 'Search everything',
      description: 'Full-text + semantic search across every note in every vault.',
      side: 'bottom' } },
  { element: '[data-tour="settings-link"]', popover: {
      title: 'Settings live here',
      description: 'Manage vaults, billing, API keys, and (soon) connect Obsidian + AI tools.',
      side: 'right' } },
  { element: '[data-tour="dashboard-root"]', popover: {
      title: 'You’re ready',
      description: 'Now let’s create your real first vault.',
      side: 'over',
      doneBtnText: 'Create my vault' } },
]
```

Anchor attrs to add:
- `data-tour="sidebar-vaults"` → VaultSwitcher
- `data-tour="folder-tree"` → FolderTree root
- `data-tour="note-viewer"` → Dashboard main column
- `data-tour="search"` → header search input/button
- `data-tour="settings-link"` → settings nav link
- `data-tour="dashboard-root"` → outermost dashboard div

**Tour controller behavior:**
- Mounts `DemoVaultProvider` → swaps query results for fixture
- Calls `driver().drive()` with steps
- `onDestroyed` (any exit):
  - POST `tour_completed` (if user reached final step) — otherwise no record beyond `tour_offered_taken`
  - Unmount DemoVaultProvider → real (empty) data returns
  - Trigger Create-First-Vault modal
- Final-step "Create my vault" click → same exit path

**Persistence (one POST each):**
- Click "Take tour" → `tour_offered_taken`
- Click "Skip" → `tour_offered_skipped`
- Reach final step → `tour_completed`

**Connections step** (deferred, drop-in when page lands):
```ts
{ element: '[data-tour="connections-link"]', popover: {
    title: 'Connect your tools',
    description: 'Pair Obsidian, link an AI model, more soon.' } }
```
Insert before final step. No other changes.

## Testing

### Backend unit (ExUnit, `test/engram/onboarding_test.exs`)
- `record_action/2` writes row with valid enum action
- `record_action/2` idempotent — second call returns `:ok`, no duplicate, no unique-index bubble
- Changeset rejects unknown action atom
- `list_actions/1` returns `[]` for new user; exact set for user with rows
- `next_step/1` resolver returns correct value given existing logic + new fields

### Backend controller (`test/engram_web/controllers/onboarding_controller_test.exs`)
- `GET /api/onboarding/status` payload shape includes `actions` + `vault_count`
- `POST /api/onboarding/actions` returns 401 unauth
- Multi-tenant: user A cannot insert action for user B
- Same action twice → 200 both, one row
- `Vaults.create_vault/2` hook fires `first_vault_created` only on first; no extra row on second
- Device-link completion fires `plugin_connected` once

### Migration test
- Backfill inserts `first_vault_created` for users with `count(vaults) > 0`; row counts assert before/after; idempotent on rerun.

### E2E (Playwright, `frontend/e2e/specs/onboarding-ftux.spec.ts`)

Use real browser, real backend, Clerk test user. Helper extension: "fresh signup that just finished onboarding wizard" fixture.

1. **Happy path with tour:** sign up → complete wizard → land dashboard → Tour-Offer modal visible → click "Take tour" → assert demo fixture rendered (look for demo note titles) → step through `.driver-popover` "Next" clicks → reach final step → click "Create my vault" → Create-Vault modal visible → submit → real dashboard, new vault → checklist shows ✅ Create vault + ✅ Take tour
2. **Skip tour:** click "Skip" → Create-Vault modal still appears → submit → checklist shows "Take the tour" item still actionable
3. **Vault modal is blocking:** no X, ESC ignored, click-outside ignored
4. **Persistence:** complete flow → reload dashboard → no modals re-fire, checklist matches stored actions
5. **Plugin connection action:** trigger device-link flow in same test → checklist updates to ✅ Install plugin without reload (TanStack invalidation works)
6. **Backfilled user:** seed user with vault pre-test → no Create-Vault modal, no first-vault prompt
7. **Mobile viewport (375x667):** checklist collapses to FAB by default; tour offer suppressed (<768px); modals still usable

## Edge cases

| Case | Decision |
|---|---|
| User closes browser mid-tour (taken but not completed) | Re-offer on next login. Only `tour_completed` OR `tour_offered_skipped` suppresses. |
| Dashboard in 2 tabs | Modal fires in both. Visual jank but safe. Defer BroadcastChannel coordination unless QA flags. |
| Mobile viewport | Tour offer suppressed <768px for v1; checklist still shows. Backlog item: mobile tour. |
| Demo fixture wikilinks | Resolve only within fixture; unresolved render as plain bracketed text (existing renderer). |
| Backfill on prod | Single migration insert wrapped in transaction. Idempotent via unique index. Validate on staging snapshot first. |
| Network failure on POST action | TanStack mutation retry (3x). Server idempotent = safe. UI does not block on success. |
| Anchor element missing at tour time | driver.js skips missing element + advances. Log warning. E2E build fails if any selector misses. |
| Active subscription, no vault (existing edge) | Backfill leaves no `first_vault_created` row → vault modal fires on next login. Intended. |
| 2-tab plugin connect race | Idempotent. Both tabs eventually invalidate + show ✅. |

## Verification

End-to-end manual + automated:

1. `mix test` — all new unit + controller tests green
2. `mix ecto.migrate` on a staging-snapshot DB; verify backfill rowcount matches `SELECT count(DISTINCT user_id) FROM vaults`
3. `cd frontend && bun run dev` + drive the SaaS local-dev stack (`make saas-dev` from workspace root) via the laptop-browser CDP tunnel (`docs/context/local-browser-cdp-tunnel.md`); walk the full flow on a fresh Clerk test signup
4. `cd frontend && bun playwright test e2e/specs/onboarding-ftux.spec.ts` — all 7 specs green
5. Mobile viewport spot-check via Chrome DevTools device-mode (375x667)
6. Reload dashboard mid-flow at every step → assert modal state matches persisted actions

## Open question (capture pre-impl)

- **Branding/copy review:** modal headlines + button labels are first-draft. Worth a pass before merging (marketing tone consistency).
- **Checklist analytics:** PostHog event on each checklist item completion would let us measure FTUX funnel. Add events under `ftux.*` namespace? (Recommend yes — cheap; PostHog already wired with `persistence:"memory"`.)
