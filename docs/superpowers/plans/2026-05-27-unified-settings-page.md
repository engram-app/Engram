# Unified Settings Page Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Consolidate scattered settings, billing, and Clerk account surfaces into one full-width Settings page rendered below a shared app header.

**Architecture:** Extract a shared `UserMenu` (Clerk `UserButton` configured to navigate into Settings, or `LocalUserMenu`) and a shared `AppHeader`. Reuse `AppHeader` in the vault layout and a new `SettingsLayout` that drops the folder tree / resizable panels. Move the `/settings` subtree under `SettingsLayout`, fold the standalone `BillingPage` into a settings section, and embed Clerk `<UserProfile>` as a Clerk-only Account section.

**Tech Stack:** React 19, react-router (v7 `react-router` package), TypeScript, Vite, Tailwind, Vitest + @testing-library/react, Clerk (`@clerk/clerk-react`).

**Working directory:** `frontend/` inside the worktree at `engram/.worktrees/unified-settings`. All paths below are relative to `frontend/`. Run tests with `bun run test` (vitest). Run a single file with `bunx vitest run <path>`.

---

## File Structure

- Create `src/layout/user-menu.tsx` — lazy Clerk/local auth control; owns the `UserButton` navigation config. Single source for the avatar control.
- Create `src/layout/app-header.tsx` — shared header (logo + main nav + ThemeToggle + UserMenu). Used by `DesktopLayout` and `SettingsLayout`.
- Modify `src/layout/app-layout.tsx` — `DesktopLayout` consumes `AppHeader`; remove inline header + the duplicated lazy auth imports + the Billing nav link.
- Modify `src/layout/mobile-layout.tsx` — consume `UserMenu`; remove duplicated lazy auth imports.
- Create `src/settings/sections.ts` — pure `buildSettingsSections(authProvider)` returning the nav list (Account prepended only for Clerk).
- Modify `src/settings/settings-layout.tsx` — becomes the full `SettingsLayout`: `AppHeader` + full-width content region wrapping the (config-aware) nav rail + `Outlet`.
- Create `src/settings/account-page.tsx` — Clerk `<UserProfile routing="path" path="/settings/account">`.
- Modify `src/billing/billing-page.tsx` — change checkout `successUrl` to `/settings/billing?status=success`.
- Delete `src/settings/billing-placeholder.tsx`.
- Modify `src/router.tsx` — move `/settings` under `SettingsLayout`; add `account/*`; config-aware index redirect; render `BillingPage` at `settings/billing`; delete standalone `/billing` route + `BillingPlaceholder` import.
- Tests: `src/settings/sections.test.ts`, `src/settings/settings-layout.test.tsx`, `src/layout/app-header.test.tsx`.

---

## Task 1: Pure settings-sections builder

**Files:**
- Create: `src/settings/sections.ts`
- Test: `src/settings/sections.test.ts`

- [ ] **Step 1: Write the failing test**

```ts
// src/settings/sections.test.ts
import { describe, expect, it } from 'vitest'
import { buildSettingsSections } from './sections'

describe('buildSettingsSections', () => {
  it('prepends Account for clerk auth', () => {
    const sections = buildSettingsSections('clerk')
    expect(sections.map((s) => s.to)).toEqual([
      'account',
      'appearance',
      'api-keys',
      'encryption',
      'billing',
    ])
  })

  it('omits Account for local auth', () => {
    const sections = buildSettingsSections('local')
    expect(sections.map((s) => s.to)).toEqual([
      'appearance',
      'api-keys',
      'encryption',
      'billing',
    ])
    expect(sections.some((s) => s.to === 'account')).toBe(false)
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bunx vitest run src/settings/sections.test.ts`
Expected: FAIL — `buildSettingsSections` not exported / module not found.

- [ ] **Step 3: Write minimal implementation**

```ts
// src/settings/sections.ts
import type { EngramConfig } from '../config'

export interface SettingsSection {
  to: string
  label: string
}

const BASE_SECTIONS: SettingsSection[] = [
  { to: 'appearance', label: 'Appearance' },
  { to: 'api-keys', label: 'API Keys' },
  { to: 'encryption', label: 'Encryption' },
  { to: 'billing', label: 'Billing' },
]

export function buildSettingsSections(
  authProvider: EngramConfig['authProvider'],
): SettingsSection[] {
  if (authProvider === 'clerk') {
    return [{ to: 'account', label: 'Account' }, ...BASE_SECTIONS]
  }
  return BASE_SECTIONS
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bunx vitest run src/settings/sections.test.ts`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add src/settings/sections.ts src/settings/sections.test.ts
git commit -m "feat(settings): config-aware settings section builder"
```

---

## Task 2: Shared UserMenu component

Extracts the lazy Clerk/local auth control into one component and configures Clerk's `UserButton` to navigate into Settings instead of opening its modal.

**Files:**
- Create: `src/layout/user-menu.tsx`

- [ ] **Step 1: Write the component**

```tsx
// src/layout/user-menu.tsx
import { lazy, Suspense } from 'react'
import { config } from '../config'

const isClerk = config.authProvider === 'clerk'

const ClerkUserButton = isClerk
  ? lazy(() =>
      import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })),
    )
  : null

const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))

export default function UserMenu() {
  return (
    <Suspense fallback={null}>
      {ClerkUserButton ? (
        <ClerkUserButton
          userProfileMode="navigation"
          userProfileUrl="/settings/account"
        />
      ) : (
        <LocalUserMenu />
      )}
    </Suspense>
  )
}
```

- [ ] **Step 2: Typecheck**

Run: `bunx tsc --noEmit`
Expected: PASS (no type errors introduced).

- [ ] **Step 3: Commit**

```bash
git add src/layout/user-menu.tsx
git commit -m "feat(layout): shared UserMenu with Clerk navigation profile mode"
```

---

## Task 3: Shared AppHeader component

**Files:**
- Create: `src/layout/app-header.tsx`
- Test: `src/layout/app-header.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
// src/layout/app-header.test.tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter } from 'react-router'
import AppHeader from './app-header'

vi.mock('../theme/theme-toggle', () => ({ default: () => null }))
vi.mock('./user-menu', () => ({ default: () => null }))

describe('AppHeader', () => {
  it('renders the wordmark and Search + Settings nav, no Billing link', () => {
    render(
      <MemoryRouter>
        <AppHeader />
      </MemoryRouter>,
    )
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Search' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Settings' })).toBeInTheDocument()
    expect(screen.queryByRole('link', { name: 'Billing' })).toBeNull()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bunx vitest run src/layout/app-header.test.tsx`
Expected: FAIL — `./app-header` module not found.

- [ ] **Step 3: Write minimal implementation**

```tsx
// src/layout/app-header.tsx
import { Link, NavLink } from 'react-router'
import ThemeToggle from '../theme/theme-toggle'
import UserMenu from './user-menu'

function HeaderLink({ to, label }: { to: string; label: string }) {
  return (
    <NavLink
      to={to}
      className={({ isActive }) =>
        `text-sm transition hover:text-foreground ${
          isActive ? 'font-medium text-foreground' : 'text-muted-foreground'
        }`
      }
    >
      {label}
    </NavLink>
  )
}

export default function AppHeader() {
  return (
    <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
      <Link
        to="/"
        className="text-lg font-semibold text-foreground hover:text-foreground/80"
      >
        Engram
      </Link>
      <nav className="flex items-center gap-3" aria-label="Main navigation">
        <HeaderLink to="/search" label="Search" />
        <HeaderLink to="/settings" label="Settings" />
        <ThemeToggle />
        <UserMenu />
      </nav>
    </header>
  )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bunx vitest run src/layout/app-header.test.tsx`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add src/layout/app-header.tsx src/layout/app-header.test.tsx
git commit -m "feat(layout): shared AppHeader, drops Billing nav link"
```

---

## Task 4: DesktopLayout consumes AppHeader

Replace the inline `<header>` in `DesktopLayout` and remove now-duplicated imports/helpers.

**Files:**
- Modify: `src/layout/app-layout.tsx`

- [ ] **Step 1: Replace the inline header**

In `src/layout/app-layout.tsx`, inside `DesktopLayout`'s returned JSX, replace the entire `<header>...</header>` block:

```tsx
      <header className="flex items-center justify-between border-b border-border bg-card px-4 py-2">
        <Link to="/" className="text-lg font-semibold text-foreground hover:text-foreground/80">
          Engram
        </Link>
        <nav className="flex items-center gap-3" aria-label="Main navigation">
          <HeaderLink to="/search" label="Search" />
          <HeaderLink to="/billing" label="Billing" />
          <HeaderLink to="/settings" label="Settings" />
          <ThemeToggle />
          <Suspense fallback={null}>
            {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
          </Suspense>
        </nav>
      </header>
```

with:

```tsx
      <AppHeader />
```

- [ ] **Step 2: Remove dead imports/helpers**

In `src/layout/app-layout.tsx`:
- Add import: `import AppHeader from './app-header'`
- Remove the `HeaderLink` function (now lives in `app-header.tsx`).
- Remove the now-unused lazy auth block:

```tsx
const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))
```

- Remove now-unused imports: `Link` and `NavLink` from `react-router` (keep `Outlet`), `Suspense` and `lazy` from `react` if no longer referenced elsewhere in the file, and `config` if no longer referenced. Keep `useEffect`/`useState`/`Button`/resizable imports.

> Note: verify each removed symbol is truly unused in the file before deleting (e.g. `Suspense`/`lazy` may be used by the existing `ClerkUserButton`/`LocalUserMenu` only). `bunx tsc --noEmit` in Step 3 will catch any over-deletion.

- [ ] **Step 3: Typecheck + run full suite**

Run: `bunx tsc --noEmit && bun run test`
Expected: PASS, no unused-symbol errors, all existing tests still green.

- [ ] **Step 4: Commit**

```bash
git add src/layout/app-layout.tsx
git commit -m "refactor(layout): DesktopLayout uses shared AppHeader"
```

---

## Task 5: MobileLayout consumes UserMenu

**Files:**
- Modify: `src/layout/mobile-layout.tsx`

- [ ] **Step 1: Swap the auth control**

In `src/layout/mobile-layout.tsx`, replace:

```tsx
          <Suspense fallback={null}>
            {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
          </Suspense>
```

with:

```tsx
          <UserMenu />
```

- [ ] **Step 2: Update imports**

In `src/layout/mobile-layout.tsx`:
- Add: `import UserMenu from './user-menu'`
- Remove the lazy auth block:

```tsx
const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))
```

- Remove now-unused imports: `config`; and from the `react` import drop `lazy` and `Suspense` if unused elsewhere (keep `useState`, `type MouseEvent`). Mobile nav already has no Billing link — leave its `HeaderLink` usages as-is.

- [ ] **Step 3: Typecheck + run suite**

Run: `bunx tsc --noEmit && bun run test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add src/layout/mobile-layout.tsx
git commit -m "refactor(layout): MobileLayout uses shared UserMenu"
```

---

## Task 6: Account page (Clerk UserProfile)

**Files:**
- Create: `src/settings/account-page.tsx`

- [ ] **Step 1: Write the component**

```tsx
// src/settings/account-page.tsx
import { lazy, Suspense } from 'react'

const UserProfile = lazy(() =>
  import('@clerk/clerk-react').then((mod) => ({ default: mod.UserProfile })),
)

export default function AccountPage() {
  return (
    <section>
      <h1 className="mb-4 text-xl font-semibold text-foreground">Account</h1>
      <Suspense fallback={<p className="text-muted-foreground">Loading account…</p>}>
        <UserProfile routing="path" path="/settings/account" />
      </Suspense>
    </section>
  )
}
```

- [ ] **Step 2: Typecheck**

Run: `bunx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/settings/account-page.tsx
git commit -m "feat(settings): Clerk account section via UserProfile"
```

---

## Task 7: SettingsLayout (header + full-width content)

Rewrite `settings-layout.tsx` to render the shared header above a full-width content region containing the config-aware nav rail and the routed `Outlet`.

**Files:**
- Modify: `src/settings/settings-layout.tsx`
- Test: `src/settings/settings-layout.test.tsx`

- [ ] **Step 1: Write the failing test**

```tsx
// src/settings/settings-layout.test.tsx
import { describe, expect, it, vi } from 'vitest'
import { render, screen } from '@testing-library/react'
import { MemoryRouter, Routes, Route } from 'react-router'
import SettingsLayout from './settings-layout'

vi.mock('../theme/theme-toggle', () => ({ default: () => null }))
vi.mock('../layout/user-menu', () => ({ default: () => null }))
vi.mock('../config', () => ({ config: { authProvider: 'clerk', clerkPublishableKey: '' } }))

function renderAt(path: string) {
  return render(
    <MemoryRouter initialEntries={[path]}>
      <Routes>
        <Route path="/settings" element={<SettingsLayout />}>
          <Route path="appearance" element={<p>appearance body</p>} />
        </Route>
      </Routes>
    </MemoryRouter>,
  )
}

describe('SettingsLayout', () => {
  it('renders the shared header, the settings nav, and the routed section', () => {
    renderAt('/settings/appearance')
    expect(screen.getByText('Engram')).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Account' })).toBeInTheDocument()
    expect(screen.getByRole('link', { name: 'Billing' })).toBeInTheDocument()
    expect(screen.getByText('appearance body')).toBeInTheDocument()
  })
})
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bunx vitest run src/settings/settings-layout.test.tsx`
Expected: FAIL — current `SettingsLayout` has no header / no Account link.

- [ ] **Step 3: Rewrite the component**

```tsx
// src/settings/settings-layout.tsx
import { NavLink, Outlet } from 'react-router'
import { config } from '../config'
import AppHeader from '../layout/app-header'
import { buildSettingsSections } from './sections'

export default function SettingsLayout() {
  const sections = buildSettingsSections(config.authProvider)

  return (
    <section className="flex h-screen flex-col bg-background text-foreground">
      <AppHeader />
      <main className="flex-1 overflow-y-auto bg-muted/40 p-6">
        <section className="mx-auto flex max-w-5xl gap-8">
          <nav aria-label="Settings sections" className="w-48 shrink-0">
            <h2 className="mb-3 text-xs font-semibold uppercase tracking-wide text-muted-foreground">
              Settings
            </h2>
            <ul className="space-y-1">
              {sections.map((s) => (
                <li key={s.to}>
                  <NavLink
                    to={s.to}
                    className={({ isActive }) =>
                      `block rounded-md px-3 py-2 text-sm transition-colors ${
                        isActive
                          ? 'bg-blue-50 dark:bg-blue-950 font-medium text-blue-700 dark:text-blue-300'
                          : 'text-gray-700 dark:text-gray-200 hover:bg-gray-100 dark:hover:bg-gray-800'
                      }`
                    }
                  >
                    {s.label}
                  </NavLink>
                </li>
              ))}
            </ul>
          </nav>
          <section className="min-w-0 flex-1">
            <Outlet />
          </section>
        </section>
      </main>
    </section>
  )
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bunx vitest run src/settings/settings-layout.test.tsx`
Expected: PASS (1 test).

- [ ] **Step 5: Commit**

```bash
git add src/settings/settings-layout.tsx src/settings/settings-layout.test.tsx
git commit -m "feat(settings): full-page SettingsLayout with shared header"
```

---

## Task 8: Billing successUrl points at settings

**Files:**
- Modify: `src/billing/billing-page.tsx`

- [ ] **Step 1: Update the checkout success URL**

In `src/billing/billing-page.tsx`, inside `PlanCard`'s `handleCheckout`, change:

```tsx
        successUrl: `${window.location.origin}/billing?status=success`,
```

to:

```tsx
        successUrl: `${window.location.origin}/settings/billing?status=success`,
```

- [ ] **Step 2: Typecheck**

Run: `bunx tsc --noEmit`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add src/billing/billing-page.tsx
git commit -m "fix(billing): return checkout success to settings billing"
```

---

## Task 9: Router rewire + delete dead billing surfaces

**Files:**
- Modify: `src/router.tsx`
- Delete: `src/settings/billing-placeholder.tsx`

- [ ] **Step 1: Rewrite the authenticated route subtree**

In `src/router.tsx`:
- Add import: `import { config } from './config'` and `import AccountPage from './settings/account-page'` and `import SettingsLayout from './settings/settings-layout'` (SettingsLayout already imported — keep one).
- Remove imports: `BillingPlaceholder` and the standalone-route usage. Keep `BillingPage` import (now used inside settings).

Replace the `OnboardingGate` children block (currently the `AppLayout` wrapper holding Dashboard/note/search/billing/settings, plus device-link and oauth) with:

```tsx
        {
          element: <OnboardingGate />,
          children: [
            {
              element: <AppLayout />,
              children: [
                { path: ROUTES.HOME, element: <Dashboard /> },
                { path: '/note/*', element: <NotePage /> },
                { path: '/search', element: <SearchPage /> },
              ],
            },
            {
              path: '/settings',
              element: <SettingsLayout />,
              children: [
                {
                  index: true,
                  element: (
                    <Navigate
                      to={config.authProvider === 'clerk' ? 'account' : 'appearance'}
                      replace
                    />
                  ),
                },
                ...(config.authProvider === 'clerk'
                  ? [{ path: 'account/*', element: <AccountPage /> }]
                  : []),
                { path: 'appearance', element: <AppearancePage /> },
                { path: 'api-keys', element: <ApiKeysPage /> },
                { path: 'encryption', element: <EncryptionPage /> },
                { path: 'billing', element: <BillingPage /> },
              ],
            },
            { path: ROUTES.DEVICE_LINK, element: <DeviceLinkPage /> },
            { path: ROUTES.OAUTH_CONSENT, element: <OAuthAuthorizePage /> },
          ],
        },
```

This removes the standalone `{ path: '/billing', element: <BillingPage /> }` route and the old `settings/billing` → `BillingPlaceholder` mapping. `SettingsLayout` now sits as a sibling of `AppLayout` (still under `OnboardingGate`), so it renders without the vault folder tree / panels.

- [ ] **Step 2: Delete the placeholder file**

```bash
git rm src/settings/billing-placeholder.tsx
```

- [ ] **Step 3: Typecheck + full suite**

Run: `bunx tsc --noEmit && bun run test`
Expected: PASS — no references to `BillingPlaceholder` remain; all tests green.

- [ ] **Step 4: Verify the dead route is gone**

Run: `grep -rn "'/billing'" src/ ; grep -rn "billing-placeholder" src/`
Expected: no standalone `/billing` route match in `router.tsx`; no `billing-placeholder` references.

- [ ] **Step 5: Commit**

```bash
git add src/router.tsx
git commit -m "feat(router): settings owns billing + account; drop standalone billing"
```

---

## Task 10: Full verification

- [ ] **Step 1: Lint + typecheck + tests**

Run: `bunx tsc --noEmit && bun run test`
Expected: all green. If the repo defines a lint script (`bun run lint` / biome), run it too and fix any new findings.

- [ ] **Step 2: Build**

Run: `bun run build`
Expected: production build succeeds.

- [ ] **Step 3: Manual smoke (laptop Chrome over SSH tunnel, chrome-devtools MCP)**

See `docs/context/local-browser-cdp-tunnel.md` in the workspace for the tunnel setup (chrome-devtools on 9222, `-L` forward for the localhost secure-context). Verify against the running app:
- `/settings` redirects to `/settings/account` (Clerk) and renders full-width below the header — no folder tree, no right panel.
- Each section loads: Account (Clerk UserProfile, with security/sessions sub-tabs working via path routing), Appearance, API Keys, Encryption, Billing.
- Billing: plan checkout opens; "Manage subscription" portal opens; completing checkout returns to `/settings/billing?status=success`.
- Top-right avatar → "Manage account" navigates to `/settings/account` (no Clerk modal pops).
- Header shows Search + Settings only (no Billing link); `/billing` directly typed resolves to not-found.
- Mobile viewport: left drawer + nav work; Settings reachable; avatar control present.
- Vault regression: folder tree, right outline panel, search unaffected.

---

## Self-Review Notes

- **Spec coverage:** §Layout→Tasks 3–5,7; §Billing→Tasks 8–9; §Account→Tasks 6,9; §Header avatar→Task 2; §Settings nav→Tasks 1,7; §Router→Task 9; §Testing→Tasks 1,3,7,10. All spec sections mapped.
- **Type consistency:** `buildSettingsSections` / `SettingsSection` used identically in Tasks 1 and 7. `UserMenu` (Task 2) consumed by Tasks 4–5 and mocked in Tasks 3,7. `AppHeader` (Task 3) consumed by Tasks 4,7.
- **Local-auth path:** Account route/nav omitted via config gate (Tasks 1,7,9); index redirect falls back to `appearance`.
