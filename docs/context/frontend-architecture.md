# Context Doc: Frontend SPA architecture

_Last verified: 2026-06-19_

## Status
Working — the React SPA in `backend/frontend/` (~325 TS files). This is the map; deep-dives are cross-linked.

## What This Is
The web app: an Obsidian-style note browser, viewer, and editor served at `app.engram.page` (saas) or same-origin by Phoenix (self-host). Single bundle, two runtime shapes (Clerk saas vs local self-host) selected from injected config.

## Stack
- **React 19** + **react-router 7** (data router) + **TanStack Query 5** (server state) + **Vite 8**.
- Tailwind + shadcn/ui (`components/ui`); **CodeMirror 6** (editor); **remark/rehype** (viewer); **Clerk** (saas auth); **Paddle.js** (billing).
- Observability: Sentry (opt-in `VITE_SENTRY_DSN`), Cloudflare Web Analytics (cookieless, `VITE_CF_BEACON_TOKEN`), PostHog (`persistence:'memory'`, autocapture off, `identify` in the auth provider — see `[[reference_cookie_audit_2026_05_24]]`).

## Bootstrap chain (`src/main.tsx`)
`Sentry.ErrorBoundary` → `StrictMode` → `BootstrapGate` (`use(configPromise)` suspends until config resolves) → `setApiBase/setWsBase` (module singletons, set BEFORE any child mounts) → `AppShell` → provider stack: `ConfigProvider` › `ThemeProvider` › `AuthProvider` (clerk **or** local, lazy by `config.authProvider`) › `QueryClientProvider` › `RouterProvider`. One auth provider is instantiated per load; the other never downloads.

## Config (`src/config.ts`, `config-context.tsx`)
`EngramConfig` = `{ authProvider, clerkPublishableKey, billingEnabled, clerkWaitlistMode, apiBase, wsBase, bootstrap? }`. Resolution order:
1. `window.__ENGRAM_CONFIG__` — Phoenix SSR-injects it (self-host, synchronous, no fetch). See `spa-state-injection.md`.
2. `/config.json` — CF-served saas (no injection).
3. `VITE_*` env defaults — Vite dev / fallback (loud console error in prod if both above fail).

`apiBase`/`wsBase` empty = same-origin (self-host); a full URL = cross-origin backend (saas, `https://api.engram.page`). `joinApiUrl` strips the `/api` prefix on saas (host-rewrite re-adds it) and keeps it same-origin.

## Routing (`src/router.tsx`, `routes.ts`)
`createAppRouter(config)` is built at runtime — **route shape depends on `authProvider` + `billingEnabled`**. Route-level **code-splitting** (`lazy`): entry surfaces (sign-in/up, layouts, guards) are eager; the viewer stack (remark/rehype + KaTeX + CodeMirror) and everything behind nav load on demand (this fixed a 1.78 MB main chunk). `installAppRouter`/`getAppRouter` expose the instance for imperative nav (e.g. Clerk's `routerPush`).

Tree:
- **Public:** `/sign-in`, `/sign-up`, `/waitlist`, `/reset-password`, catch-all `*` → NotFound.
- **`AuthGuard`** → authenticated:
  - `/onboard/*` (agreement → billing → tools → vault) — under AuthGuard but NOT OnboardingGate (avoids redirect loop).
  - `/link` (device flow), `/oauth/consent` — outside OnboardingGate (reachable mid-onboarding, e.g. an MCP client connecting during signup).
  - **`OnboardingGate`** → **`OnboardingShell`** (tour offer, first-vault modal, checklist — only on the main surface) → **`AppLayout`**:
    - `/` Dashboard (folder tree) · `/note/:id` `VaultItemPage` (resolves note vs attachment) · `/settings/*`.
- **Settings:** account (`account-page` for Clerk, `account-page-local` for local), vaults, connections (`/settings/api-keys` redirects here), `billing` (only if `billingEnabled`), `admin` (only if `authProvider === 'local'`).
- `RootLayout` mounts `UpgradeDialogProvider` inside the router so a 402 anywhere opens the upgrade modal via a module-level handler.

## Data / realtime / sync (`src/api/`)
- `base.ts` — `apiBase`/`wsBase` singletons + `joinApiUrl`/`joinWsUrl` + `useApiUrl`/`useWsUrl` hooks.
- `client.ts` — singleton `api` object; `setTokenGetter` injects the auth token (wired by the auth provider).
- `query-client.ts` + `queries.ts` — the TanStack Query client + all server-state hooks (notes/folders/search/vaults).
- `channel.ts` + `use-channel.ts` — Phoenix **Channels** over WebSocket for realtime (`note:changes` fan-out). See `channel-event-contract.md`.
- `cursor.ts` + `cursor-sync.ts` — **cursor-pull sync** (device cursors + gap-filler via `GET /api/sync/changes`); `device-id.ts` issues the `X-Device-Id`. See the sync-protocol doc.
- `active-vault.ts`, `oauth.ts` — active-vault selection + OAuth client.

## Viewer + editor (`src/viewer/`)
- `note-view.tsx` — remark/rehype Obsidian-style render (CommonMark+GFM, wikilinks, embeds, callouts, KaTeX, `mermaid-block`, auto-linked headings, `note-toc`).
- `note-editor.tsx` — CodeMirror 6; `use-autosave.ts` autosaves (Saving…/Saved/Save failed→Retry — no Save button).
- `conflict-bar.tsx` + `merge.ts` — on a 409 the editor refetches, 3-way-merges, retries; true overlaps surface a non-blocking ConflictBar (Keep mine / Take theirs / View merge). `note-page.tsx` has the Reading/Edit toggle (`mode: 'live'|'reading'`).
- `vault-item-page.tsx` resolves `/note/:id` to `note-page` or `attachment-page` (`attachment-img`/`pdf-view`/`attachment-fallback`). `folder-tree.tsx` + `tree/` + `tree-actions/` are the headless-tree file tree — see `folder-tree-optimistic-rebuild.md`. Decrypt perf in `read-path-decrypt-perf.md`.

## App shell (`src/layout/`)
`app-layout` (shell) + `app-sidebar`/`rail`/`files-panel` (left nav + folder tree) + `search-panel` (the only search surface — no command palette) + `user-menu` + `vault-switcher` + `mobile-layout`. Shared auth chrome (`auth-shell`/`auth-panel`/`auth-backdrop`) is reused by sign-in/up + device-link + OAuth consent.

## Onboarding, billing, settings
- **`src/onboarding/`** — gate + layout + shell + the agreement/billing/tools/vault wizard. See `[[project_signup_wizard]]`.
- **`src/billing/`** + `src/lib/paddle-*` — `upgrade-dialog-provider` (402 → modal), `billing-page`, plan cards, Paddle.js overlay. Consumer contract in `billing-tier-frontend-contract.md`.
- **`src/settings/`** — settings-layout + the per-tab pages above.

## Build / deploy
Vite build → `priv/static/app/`. Self-host: Phoenix serves the SPA same-origin (`apiBase=""`). Saas: built + deployed to Cloudflare (Workers) separately from the backend (`apiBase=https://api.engram.page`). See `../engram-workspace/docs/context/frontend-eject-cloudflare-workers.md`.

## Gotchas
- The dual-runtime is **config-driven, not build-driven** — same bundle, behavior flips on resolved `EngramConfig`. Don't hardcode saas-only assumptions.
- `apiBase`/`wsBase` are module singletons set in `BootstrapGate` before first render; non-React callers use `getApiBase()`/`getWsBase()`, not a hook.
- It is NOT SSR — first-paint-correct UI comes from injected config state, not server rendering (see `spa-state-injection.md`, #353).

## References
- `spa-state-injection.md`, `folder-tree-optimistic-rebuild.md`, `read-path-decrypt-perf.md`, `billing-tier-frontend-contract.md`, `channel-event-contract.md`
- `../engram-workspace/docs/api-contract.md` (REST/WS endpoints), `frontend-eject-cloudflare-workers.md` (deploy)
- code: `src/main.tsx`, `src/router.tsx`, `src/config.ts`, `src/api/`
