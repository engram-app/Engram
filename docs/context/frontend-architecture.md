# Context Doc: Frontend SPA architecture

_Last verified: 2026-10-03_

## Status
Working. The React SPA in `frontend/`. This is the map; deep-dives are cross-linked.

## What This Is
The web app: an Obsidian-style note browser, viewer, and editor served at `app.engram.page` (saas) or same-origin by Phoenix (self-host). Single bundle, two runtime shapes (Clerk saas vs local self-host) selected from resolved config.

## Stack
- **React 19** + **react-router 8** (data router) + **TanStack Query 5** (server state) + **Vite 8** (rolldown).
- Tailwind + shadcn/ui (`components/ui`); **CodeMirror 6** via `@atomic-editor/editor` + yCollab (editor); **remark/rehype** (viewer); **Clerk** (saas auth); **Paddle.js** (billing).
- Observability: Sentry (opt-in `VITE_SENTRY_DSN`, dynamic import), Cloudflare Web Analytics (cookieless, `VITE_CF_BEACON_TOKEN`), PostHog (`persistence:'memory'`, autocapture off, dynamic import, `identify` in the auth provider).

## Bootstrap chain (`src/main.tsx`)
`RootErrorBoundary` → `StrictMode` → `BootstrapGate` (`use(configPromise)` suspends until config resolves) → `setApiBase/setWsBase` (module singletons, set BEFORE any child mounts) → provider stack: `ConfigProvider` › `ThemeProvider` › `AuthProvider` (clerk **or** local, by `config.authProvider`) › `QueryClientProvider` › `RouterProvider`. One auth provider is instantiated per load; the other never downloads.

## Config (`src/config.ts`, `config-context.tsx`)
`EngramConfig` = `{ authProvider, clerkPublishableKey, billingEnabled, apiBase, wsBase, tracingEnabled, bootstrap? }`. Resolution order:
1. `window.__ENGRAM_CONFIG__`. Self-host: Phoenix injects it per request. Saas: the `build:saas` Vite plugin inlines it into `index.html` (`VITE_INLINE_BOOTSTRAP_CONFIG=1`, mapping in `scripts/bootstrap-config.ts`). See `spa-state-injection.md`.
2. `/config.json` fallback.
3. `VITE_*` env defaults (Vite dev; loud console error in prod if both above fail).

`apiBase`/`wsBase` empty = same-origin (self-host); a full URL = cross-origin backend (saas, `https://api.engram.page`). `joinApiUrl` strips the `/api` prefix on saas (host-rewrite re-adds it) and keeps it same-origin.

## Routing (`src/router.tsx`, `routes.ts`)
`createAppRouter(config)` is built at runtime; **route shape depends on `authProvider` + `billingEnabled`**. Route-level code-splitting (`lazy`): the viewer stack and everything behind nav load on demand. `installAppRouter`/`getAppRouter` expose the instance for imperative nav (e.g. Clerk's `routerPush`). Root `errorElement` is `RouteErrorBoundary`.

Tree:
- **Public:** `/sign-in`, `/sign-up`, `/reset-password`, catch-all `*` → NotFound. Dev-only `/__qc/connectors`.
- **`AuthGuard`** → authenticated:
  - `/onboard/*` (agreement → billing → tools → vault): under AuthGuard but NOT OnboardingGate (avoids redirect loop).
  - `/link` (device flow), `/oauth/consent`: outside OnboardingGate (reachable mid-onboarding).
  - **`OnboardingGate`** → **`OnboardingShell`** → **`AppLayout`**:
    - `/` and `/v` → `VaultRedirect` · `/v/:slug` → `VaultRoute` · `/v/:slug/:itemId` → `VaultItemPage` (note vs attachment) · `/note/:id` → `LegacyNoteRedirect`.
- Every vault-scoped URL sits under `/v`; build paths with `vaultPath`/`noteHref` in `routes.ts`. Hard-loadable URLs are listed in `spa-routes.json` (parity-tested against the React and Phoenix routers).
- **Settings** is a dialog addressed by URL hash (`#settings/<section>`, `settings/settings-hash.ts`, `SettingsOverlayHost`): account, vaults, connections, billing (only if `billingEnabled`), admin (only if `authProvider === 'local'`). `/settings` and `/settings/*` are `LegacySettingsRedirect`.
- `RootLayout` mounts `UpgradeDialogProvider` inside the router so a 402 anywhere opens the upgrade modal.

## Data / realtime / sync
- `api/base.ts`: `apiBase`/`wsBase` singletons + `joinApiUrl`/`joinWsUrl` + `useApiUrl`/`useWsUrl` hooks.
- `api/client.ts`: singleton `api` object; `authFetch` sets `Authorization`, `X-Vault-ID`, `X-Device-Id` (`device-id.ts`), and `traceparent` when `tracingEnabled`.
- `api/query-client.ts` + `api/queries.ts`: TanStack Query client + server-state hooks. One `['vault-tree']` query feeds the sidebar; see `folder-tree-optimistic-rebuild.md`.
- `api/channel.ts` + `api/use-channel.ts`: Phoenix Channels for realtime (`note_changed` fan-out, coalesced into tree patches via `api/vault-tree-patch.ts`). See `channel-event-contract.md`.
- `src/crdt/` + `api/crdt-ops.ts`: the CRDT sync client (manager, session, durable op-queue, genesis).
- `api/active-vault.ts`, `api/vault-slug.ts`, `api/oauth.ts`: active-vault selection, slug mapping, OAuth client. See `stale-active-vault-404s.md`.

## Viewer + editor (`src/viewer/`)
- `note-view.tsx`: Reading mode, remark/rehype Obsidian-style render (GFM, wikilinks, embeds, callouts, KaTeX, `mermaid-block`, `note-toc`). Wikilinks: `spa-wikilink-resolution.md`.
- `note-page.tsx` + `note-editor.tsx` + `editor/`: live-preview editor on `@atomic-editor/editor` with our decorations. See `codemirror-live-preview-extensions.md`; mobile toolbar in `mobile-editor-toolbar.md`.
- `vault-item-page.tsx` resolves an item to `note-page` or `attachment-page` (`attachment-img`/`pdf-view`/`attachment-fallback`). `folder-tree.tsx` + `tree/` + `tree-actions/` are the headless-tree file tree; see `folder-tree-optimistic-rebuild.md`. Decrypt perf in `read-path-decrypt-perf.md`.

## App shell (`src/layout/`)
`app-shell.ts` (one lazy barrel for layouts, see `frontend-login-boot-perf.md`) + `app-layout` + `app-sidebar`/`rail`/`files-panel` (left nav + folder tree) + `search-panel` (the only search surface) + `user-menu` + `vault-switcher` + `mobile-layout`. Shared auth chrome (`auth-shell`/`auth-panel`/`auth-backdrop`) is reused by sign-in/up + device-link + OAuth consent.

## Onboarding, billing, settings
- **`src/onboarding/`**: gate + layout + shell + the agreement/billing/tools/vault wizard.
- **`src/billing/`** + `src/lib/paddle-*`: `upgrade-dialog-provider` (402 → modal), billing page, plan cards, Paddle.js overlay. Consumer contract in `billing-tier-frontend-contract.md`.
- **`src/settings/`**: settings overlay + per-section pages.

## Build / deploy
- Self-host: `bun run build` (`build:selfhost`) → `../priv/static/app/`; Phoenix serves the SPA same-origin (`apiBase=""`).
- Saas: `bun run build:saas` → `frontend/dist`, served by the Cloudflare Worker `engram-frontend` (`frontend/wrangler.jsonc`). The Worker script runs only for `/api/mcp*` (410) and `/ph*` (PostHog proxy); everything else is static assets with SPA fallback. The `app.engram.page` route is owned by Terraform (engram-infra `main/cloudflare/workers.tf`), not wrangler.
- Every main push only uploads a zero-traffic version (`deploy-frontend` in `verify.yml`). Prod traffic moves only via `frontend-promote.yml`, dispatched by engram-infra's prod apply after the backend ECS rollout is healthy, so the backend ships before the frontend for the same release. Verifying a ship: `frontend-ship-verification-bundle-grep.md`. Host layout: `../engram-workspace/docs/context/public-url-host-split.md`.

## Gotchas
- The dual-runtime is **config-driven, not build-driven** at the component level: behavior flips on resolved `EngramConfig`. Don't hardcode saas-only assumptions.
- `apiBase`/`wsBase` are module singletons set in `BootstrapGate` before first render; non-React callers use `getApiBase()`/`getWsBase()`, not a hook.
- It is NOT SSR. First-paint-correct UI comes from injected config state (`spa-state-injection.md`).
- **Every new request header the SPA sends cross-origin must be added to `access-control-allow-headers` in `lib/engram_web/plugs/cors.ex` in the same change**, or the saas preflight fails and every API call dies (2026-06-20: `x-device-id`). Latent instance: `authFetch` sets `traceparent` when `tracingEnabled`, and cors.ex does not allow it. Prod is safe only because `scripts/bootstrap-config.ts` does not ship `tracingEnabled`, so it resolves false (`VITE_TRACING_ENABLED=true` in `.env.production` is dead). Wiring it in without updating cors.ex breaks saas.

## References
- `spa-state-injection.md`, `folder-tree-optimistic-rebuild.md`, `read-path-decrypt-perf.md`, `billing-tier-frontend-contract.md`, `channel-event-contract.md`, `frontend-login-boot-perf.md`
- `../engram-workspace/docs/api-contract.md` (REST/WS endpoints), `../engram-workspace/docs/context/public-url-host-split.md` (hosts)
- code: `src/main.tsx`, `src/router.tsx`, `src/config.ts`, `src/api/`, `src/crdt/`, `frontend/wrangler.jsonc`
