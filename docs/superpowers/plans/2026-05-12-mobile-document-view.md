# Mobile Document View Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Below `md` (768px), replace the desktop three-column resizable layout with a single-column document view plus left and right `Sheet` drawers (file picker + ToC), and tune the editor + typography for touch.

**Architecture:** Branch at `app-layout.tsx` on a `useMediaQuery('(min-width: 768px)')` hook. Above `md` → existing `ResizablePanelGroup`. Below `md` → a new `MobileLayout` rendering a sticky header with hamburger + ToC triggers, both opening shadcn `Sheet`s carrying the same `VaultSwitcher`/`FolderTree` and `RightSidebarContext.content` already in use. Drawer state is component-local — never persisted.

**Tech Stack:** React 19, Tailwind v4, shadcn/ui (`Sheet` is new — Radix Dialog under the hood), `react-router` `Outlet`, Playwright for verification. Frontend has **no** unit-test runner; verification happens via Playwright + manual viewport resize.

---

## File map

| Path | Status | Responsibility |
|------|--------|----------------|
| `frontend/src/hooks/use-media-query.ts` | new | `window.matchMedia` hook, SSR-safe default, listener cleanup |
| `frontend/src/components/ui/sheet.tsx` | new (via `bunx --bun shadcn add sheet`) | shadcn Sheet primitive (Radix Dialog) |
| `frontend/src/layout/mobile-layout.tsx` | new | Sticky header + two `Sheet`s + `<Outlet/>` |
| `frontend/src/layout/app-layout.tsx` | modify | Branch on `useMediaQuery`; render mobile or desktop layout |
| `frontend/src/viewer/note-view.tsx` | modify | Responsive padding + typography (`px-4 sm:px-8 lg:px-12`, `prose lg:prose-lg`) |
| `frontend/src/viewer/note-editor.tsx` | modify | CodeMirror theme extension forcing 16px font on `.cm-content` |
| `frontend/src/main.css` | modify | `html { scroll-padding-top: 4rem }` |
| `frontend/e2e/mobile.spec.ts` | new | Playwright mobile-viewport smoke test |
| `mix.exs` | modify | Bump version (pre-push hook requires it) |

---

## Task 1: `use-media-query` hook

**Files:**
- Create: `frontend/src/hooks/use-media-query.ts`

- [ ] **Step 1: Confirm `frontend/src/hooks/` doesn't exist yet, create directory**

```bash
ls frontend/src/hooks 2>/dev/null || mkdir -p frontend/src/hooks
```

- [ ] **Step 2: Write the hook**

```ts
import { useEffect, useState } from 'react'

/**
 * SSR-safe matchMedia hook. Returns `false` on the server (no matchMedia),
 * then re-renders with the real value on mount. Subscribes to changes via
 * `addEventListener('change')` and cleans up on unmount.
 */
export function useMediaQuery(query: string): boolean {
  const getMatch = () => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') {
      return false
    }
    return window.matchMedia(query).matches
  }

  const [matches, setMatches] = useState<boolean>(getMatch)

  useEffect(() => {
    if (typeof window === 'undefined' || typeof window.matchMedia !== 'function') return
    const mql = window.matchMedia(query)
    const handler = (e: MediaQueryListEvent) => setMatches(e.matches)
    // Sync once on mount in case the initial render mismatched (SSR / hydration).
    setMatches(mql.matches)
    mql.addEventListener('change', handler)
    return () => mql.removeEventListener('change', handler)
  }, [query])

  return matches
}
```

- [ ] **Step 3: TypeScript check**

Run: `cd frontend && bun run build`
Expected: PASS (no TS errors). Note: this also rebuilds Vite — slow but the project's only TS check.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/hooks/use-media-query.ts
git commit -m "feat(frontend): add useMediaQuery hook"
```

---

## Task 2: shadcn Sheet primitive

**Files:**
- Create: `frontend/src/components/ui/sheet.tsx` (generated)

- [ ] **Step 1: Install Sheet via shadcn CLI**

Run: `cd frontend && bunx --bun shadcn@latest add sheet`
Expected: creates `src/components/ui/sheet.tsx`. CLI may prompt to overwrite — say no to anything else.

- [ ] **Step 2: Verify import resolves**

Run: `cd frontend && bun run build`
Expected: PASS. If `@radix-ui/react-dialog` is missing, install it: `bun add @radix-ui/react-dialog`. The shadcn CLI normally adds this automatically.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/components/ui/sheet.tsx frontend/package.json frontend/bun.lock 2>/dev/null
git commit -m "feat(frontend): add shadcn Sheet primitive"
```

---

## Task 3: `MobileLayout` component

**Files:**
- Create: `frontend/src/layout/mobile-layout.tsx`

- [ ] **Step 1: Write the component**

```tsx
import { Menu, PanelRightOpen } from 'lucide-react'
import { lazy, Suspense, useState } from 'react'
import { Link, NavLink, Outlet } from 'react-router'
import { Button } from '@/components/ui/button'
import { ScrollArea } from '@/components/ui/scroll-area'
import {
  Sheet,
  SheetContent,
  SheetHeader,
  SheetTitle,
  SheetTrigger,
} from '@/components/ui/sheet'
import { config } from '../config'
import ThemeToggle from '../theme/theme-toggle'
import FolderTree from '../viewer/folder-tree'
import { useRightSidebar } from './right-sidebar-context'
import VaultSwitcher from './vault-switcher'

const isClerk = config.authProvider === 'clerk'
const ClerkUserButton = isClerk
  ? lazy(() => import('@clerk/clerk-react').then((mod) => ({ default: mod.UserButton })))
  : null
const LocalUserMenu = lazy(() => import('../auth/local-user-menu'))

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

export default function MobileLayout() {
  const { content: rightContent } = useRightSidebar()
  const [leftOpen, setLeftOpen] = useState(false)
  const [rightOpen, setRightOpen] = useState(false)

  return (
    <section className="flex h-dvh flex-col bg-background text-foreground">
      <header className="sticky top-0 z-20 flex shrink-0 items-center justify-between border-b border-border bg-card px-2 py-2">
        <section className="flex items-center gap-1">
          <Sheet open={leftOpen} onOpenChange={setLeftOpen}>
            <SheetTrigger asChild>
              <Button variant="ghost" size="icon" aria-label="Open files" className="h-11 w-11">
                <Menu />
              </Button>
            </SheetTrigger>
            <SheetContent side="left" className="w-[85vw] max-w-sm p-0">
              <SheetHeader className="border-b border-border px-3 py-2">
                <SheetTitle>Files</SheetTitle>
              </SheetHeader>
              <ScrollArea className="h-[calc(100dvh-3rem)]" onClick={() => setLeftOpen(false)}>
                <VaultSwitcher />
                <FolderTree />
              </ScrollArea>
            </SheetContent>
          </Sheet>
          <Link to="/" className="text-base font-semibold text-foreground">
            Engram
          </Link>
        </section>
        <nav className="flex items-center gap-1" aria-label="Main navigation">
          <HeaderLink to="/search" label="Search" />
          <HeaderLink to="/settings" label="Settings" />
          <ThemeToggle />
          <Suspense fallback={null}>
            {ClerkUserButton ? <ClerkUserButton /> : <LocalUserMenu />}
          </Suspense>
          {rightContent && (
            <Sheet open={rightOpen} onOpenChange={setRightOpen}>
              <SheetTrigger asChild>
                <Button
                  variant="ghost"
                  size="icon"
                  aria-label="Open outline"
                  className="h-11 w-11"
                >
                  <PanelRightOpen />
                </Button>
              </SheetTrigger>
              <SheetContent side="right" className="w-[85vw] max-w-sm p-0">
                <SheetHeader className="border-b border-border px-3 py-2">
                  <SheetTitle>On this page</SheetTitle>
                </SheetHeader>
                <ScrollArea className="h-[calc(100dvh-3rem)]" onClick={() => setRightOpen(false)}>
                  {rightContent}
                </ScrollArea>
              </SheetContent>
            </Sheet>
          )}
        </nav>
      </header>
      <main className="flex-1 overflow-y-auto bg-muted/40 text-foreground">
        <Outlet />
      </main>
    </section>
  )
}
```

Notes:
- `onClick={() => setLeft/RightOpen(false)}` on the `ScrollArea` closes the drawer when a list item is clicked. Item-level handlers (like ToC anchor links inside `NoteToc`) keep working; the outer click handler fires after, dismissing the drawer.
- `h-dvh` uses the modern dynamic viewport unit; iOS Safari shrinks it as the URL bar appears, unlike `h-screen`.
- 44px touch targets via `h-11 w-11`. Default shadcn `size="icon"` is 36px.

- [ ] **Step 2: TypeScript check**

Run: `cd frontend && bun run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/layout/mobile-layout.tsx
git commit -m "feat(frontend): add MobileLayout with file + ToC drawers"
```

---

## Task 4: Wire `MobileLayout` into `AppLayout`

**Files:**
- Modify: `frontend/src/layout/app-layout.tsx`

- [ ] **Step 1: Edit `app-layout.tsx` — add imports and branch**

In the existing file, add the import at the top with the other layout imports:

```tsx
import { useMediaQuery } from '@/hooks/use-media-query'
import MobileLayout from './mobile-layout'
```

Then in `AppLayoutInner`, immediately after the `const { data: billing } = useBillingStatus()` line, add:

```tsx
const isDesktop = useMediaQuery('(min-width: 768px)')
```

And replace the existing top-level `return (...)` body with:

```tsx
return (
  <>
    {billing?.subscription?.status === 'trialing' && billing.trial_days_remaining > 0 && billing.trial_days_remaining <= 3 && (
      <aside className="bg-amber-50 px-4 py-2 text-center text-sm text-amber-900 dark:bg-amber-950/40 dark:text-amber-100" role="alert">
        {billing.trial_days_remaining} days left in your trial.
      </aside>
    )}
    {isDesktop ? <DesktopLayout /> : <MobileLayout />}
  </>
)
```

Then extract the rest (the `<section className="flex h-screen flex-col ..."> ... </section>` block — including header, panel group, and the `toggleLeft`/`toggleRight`/`useEffect`/`hasRight`/`leftRef`/`rightRef`/`leftCollapsed`/`rightCollapsed`/`setRightCollapsed` machinery) into a new component declared in the same file:

```tsx
function DesktopLayout() {
  const leftRef = useRef<ImperativePanelHandle>(null)
  const rightRef = useRef<ImperativePanelHandle>(null)
  const [leftCollapsed, setLeftCollapsed] = useState(false)
  const { content: rightContent, collapsed: rightCollapsed, setCollapsed: setRightCollapsed } =
    useRightSidebar()

  const toggleLeft = () => {
    const p = leftRef.current
    if (!p) return
    if (p.isCollapsed()) p.expand()
    else p.collapse()
  }

  const toggleRight = () => {
    const p = rightRef.current
    if (!p) return
    if (p.isCollapsed()) p.expand()
    else p.collapse()
  }

  useEffect(() => {
    if (rightContent == null) {
      rightRef.current?.collapse()
    } else if (rightRef.current?.isCollapsed()) {
      rightRef.current?.expand()
    }
  }, [rightContent])

  const hasRight = rightContent != null

  return (
    <section className="flex h-screen flex-col bg-background text-foreground">
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

      <ResizablePanelGroup
        direction="horizontal"
        autoSaveId="engram:app-layout"
        className="flex-1"
      >
        <ResizablePanel
          id="sidebar"
          order={1}
          ref={leftRef}
          defaultSize={18}
          minSize={12}
          maxSize={40}
          collapsible
          collapsedSize={0}
          onCollapse={() => setLeftCollapsed(true)}
          onExpand={() => setLeftCollapsed(false)}
          className="border-r border-border bg-card"
        >
          <div className="flex h-full flex-col">
            <div className="flex shrink-0 items-center justify-end border-b border-border px-1 py-1">
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleLeft}
                aria-label="Collapse sidebar"
                title="Collapse sidebar"
              >
                <PanelLeftClose />
              </Button>
            </div>
            <ScrollArea className="flex-1">
              <VaultSwitcher />
              <FolderTree />
            </ScrollArea>
          </div>
        </ResizablePanel>
        <ResizableHandle withHandle />
        <ResizablePanel id="main" order={2} defaultSize={60} minSize={30}>
          <main className="relative h-full overflow-hidden bg-muted/40 p-6 text-foreground">
            {leftCollapsed && (
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleLeft}
                aria-label="Expand sidebar"
                title="Expand sidebar"
                className="absolute left-2 top-2 z-10 bg-card/80 backdrop-blur"
              >
                <PanelLeftOpen />
              </Button>
            )}
            {hasRight && rightCollapsed && (
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleRight}
                aria-label="Expand outline"
                title="Expand outline"
                className="absolute right-2 top-2 z-10 bg-card/80 backdrop-blur"
              >
                <PanelRightOpen />
              </Button>
            )}
            <Outlet />
          </main>
        </ResizablePanel>
        <ResizableHandle withHandle />
        <ResizablePanel
          id="right-sidebar"
          order={3}
          ref={rightRef}
          defaultSize={22}
          minSize={12}
          maxSize={40}
          collapsible
          collapsedSize={0}
          onCollapse={() => setRightCollapsed(true)}
          onExpand={() => setRightCollapsed(false)}
          className="border-l border-border bg-card"
        >
          <div className="flex h-full flex-col">
            <div className="flex shrink-0 items-center justify-start border-b border-border px-1 py-1">
              <Button
                variant="ghost"
                size="icon-sm"
                onClick={toggleRight}
                aria-label="Collapse outline"
                title="Collapse outline"
              >
                <PanelRightClose />
              </Button>
            </div>
            <ScrollArea className="flex-1">{rightContent}</ScrollArea>
          </div>
        </ResizablePanel>
      </ResizablePanelGroup>
    </section>
  )
}
```

After this refactor, `AppLayoutInner` keeps only:
- `useChannel()` call
- `useBillingStatus()` call
- `useMediaQuery` call
- The new branched return

`useChannel` belongs at the outer level so it runs in both layouts. `useRightSidebar` moves into `DesktopLayout` (which uses `rightContent`, `rightCollapsed`, `setRightCollapsed`). `MobileLayout` calls `useRightSidebar` internally already.

- [ ] **Step 2: TypeScript check**

Run: `cd frontend && bun run build`
Expected: PASS.

- [ ] **Step 3: Manual smoke test**

Run dev server (or rely on the running `make dev`); resize Chrome to ~390px wide. The header should swap to compact form with a hamburger; resize handles should disappear. Resize back to >768px; old layout returns.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/layout/app-layout.tsx
git commit -m "feat(frontend): branch AppLayout on viewport width"
```

---

## Task 5: Responsive prose padding + typography in `note-view.tsx`

**Files:**
- Modify: `frontend/src/viewer/note-view.tsx`

- [ ] **Step 1: Edit `note-view.tsx`**

Two replacements in the existing file:

Change the `<article>` className:

```tsx
<article className="w-full px-8 py-8 lg:px-12 lg:py-10">
```

to:

```tsx
<article className="w-full px-4 py-6 sm:px-8 sm:py-8 lg:px-12 lg:py-10">
```

Change the `<section>` className:

```tsx
<section className="prose prose-neutral max-w-none dark:prose-invert lg:prose-lg">
```

to:

```tsx
<section className="prose prose-neutral max-w-none dark:prose-invert lg:prose-lg">
```

(unchanged — `prose` already responsive enough; `lg:prose-lg` already gates to desktop). The goal here is only padding.

- [ ] **Step 2: TypeScript check**

Run: `cd frontend && bun run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/viewer/note-view.tsx
git commit -m "feat(frontend): tighten note padding on small viewports"
```

---

## Task 6: 16px CodeMirror font (block iOS focus-zoom)

**Files:**
- Modify: `frontend/src/viewer/note-editor.tsx`

- [ ] **Step 1: Edit `note-editor.tsx` — add a theme extension**

Replace the body of the component with:

```tsx
import { markdown } from '@codemirror/lang-markdown'
import { EditorView } from '@codemirror/view'
import CodeMirror from '@uiw/react-codemirror'
import { useTheme } from '../theme/theme-provider'

interface NoteEditorProps {
  value: string
  onChange: (next: string) => void
}

// 16px on .cm-content prevents iOS Safari from auto-zooming when the
// soft keyboard opens. lineWrapping stays on.
const mobileSafeTheme = EditorView.theme({
  '.cm-content': { fontSize: '16px' },
  '.cm-scroller': { fontFamily: 'inherit' },
})

export default function NoteEditor({ value, onChange }: NoteEditorProps) {
  const { resolved } = useTheme()

  return (
    <CodeMirror
      value={value}
      onChange={onChange}
      theme={resolved}
      extensions={[markdown(), EditorView.lineWrapping, mobileSafeTheme]}
      basicSetup={{
        lineNumbers: false,
        foldGutter: false,
        highlightActiveLine: false,
        highlightActiveLineGutter: false,
        autocompletion: false,
      }}
      className="min-h-[70vh] rounded-md border border-border bg-muted/30"
    />
  )
}
```

Note: `text-sm` removed from the className because the theme now sets size explicitly. The desktop look stays close (CodeMirror inherits 16px which matches `prose` body anyway).

- [ ] **Step 2: TypeScript check**

Run: `cd frontend && bun run build`
Expected: PASS.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/viewer/note-editor.tsx
git commit -m "feat(frontend): force 16px CodeMirror font to block iOS focus-zoom"
```

---

## Task 7: `scroll-padding-top` so ToC anchors land below sticky header

**Files:**
- Modify: `frontend/src/main.css`

- [ ] **Step 1: Locate the top of `main.css` and add a rule**

Add this rule near the existing `html`/`:root` block (after the shadcn token blocks; if uncertain, append to the bottom of the file):

```css
html {
  scroll-padding-top: 4rem;
}
```

- [ ] **Step 2: Sanity check**

Run: `cd frontend && bun run build`
Expected: PASS. No CSS warnings.

- [ ] **Step 3: Commit**

```bash
git add frontend/src/main.css
git commit -m "feat(frontend): scroll-padding-top for ToC anchors under sticky header"
```

---

## Task 8: Playwright mobile-viewport smoke test

**Files:**
- Create: `frontend/e2e/mobile.spec.ts`

- [ ] **Step 1: Check existing Playwright config + test helpers**

Run: `cat frontend/playwright.config.ts | head -40` and `cat frontend/e2e/dark-mode.spec.ts | head -30`
Expected: confirm the existing `signIn` helper pattern (registerUser + signIn) used in `dark-mode.spec.ts`. The new spec reuses the same idiom.

- [ ] **Step 2: Write the spec**

```ts
import { test, expect } from '@playwright/test'

const TEST_PASSWORD = 'E2eTestPass!99'

async function registerUser(baseURL: string, email: string) {
  const res = await fetch(`${baseURL}/api/auth/register`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: TEST_PASSWORD }),
  })
  if (res.status === 422) return
  if (!res.ok) throw new Error(`Register failed: ${res.status} ${await res.text()}`)
}

function testEmail(label: string) {
  return `e2e-mobile-${Date.now()}-${label}@test.com`
}

async function signIn(page: import('@playwright/test').Page, email: string) {
  await page.goto('/sign-in/')
  await page.getByLabel('Email').fill(email)
  await page.getByLabel('Password', { exact: true }).fill(TEST_PASSWORD)
  await page.getByRole('button', { name: /sign in/i }).click()
  await expect(page).toHaveURL('/')
}

test.describe('Mobile layout', () => {
  test.use({ viewport: { width: 390, height: 844 } })

  test('header shows hamburger; tapping opens files drawer', async ({ page, baseURL }) => {
    const email = testEmail('files')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    const filesTrigger = page.getByRole('button', { name: 'Open files' })
    await expect(filesTrigger).toBeVisible()
    await filesTrigger.click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await expect(page.getByRole('heading', { name: 'Files' })).toBeVisible()
  })

  test('desktop resize handles are not rendered on mobile', async ({ page, baseURL }) => {
    const email = testEmail('handles')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    // The desktop layout renders resize handles with role="separator". Mobile
    // layout renders zero.
    await expect(page.locator('[data-panel-resize-handle-id]')).toHaveCount(0)
  })

  test('drawers start closed on every navigation', async ({ page, baseURL }) => {
    const email = testEmail('reset')
    await registerUser(baseURL!, email)
    await signIn(page, email)

    await page.getByRole('button', { name: 'Open files' }).click()
    await expect(page.getByRole('dialog')).toBeVisible()
    await page.goto('/settings')
    await expect(page.getByRole('dialog')).toHaveCount(0)
  })
})
```

- [ ] **Step 3: Run the spec against the local stack**

Run: `cd frontend && bun run test:e2e:local -- mobile.spec.ts`
Expected: 3 tests pass.

If `mobile.spec.ts` cannot be passed positionally for the project, run `bun run test:e2e:local -- --grep "Mobile layout"` instead.

- [ ] **Step 4: Commit**

```bash
git add frontend/e2e/mobile.spec.ts
git commit -m "test(e2e): mobile viewport smoke for drawer layout"
```

---

## Task 9: Version bump (pre-push hook requirement)

**Files:**
- Modify: `mix.exs`

- [ ] **Step 1: Bump patch version**

Edit `mix.exs` line 6 — change `version: "0.5.75"` to `version: "0.5.76"`.

- [ ] **Step 2: Commit**

```bash
git add mix.exs
git commit -m "chore(release): bump to 0.5.76"
```

---

## Task 10: Push and open PR

- [ ] **Step 1: Push branch**

Run: `git push -u origin feat/mobile-document-view`
Expected: success; pre-push hook passes (lint, compile, credo, sobelow).

- [ ] **Step 2: Open PR**

Run:

```bash
gh pr create --title "feat(ui): mobile-friendly document view" --body "$(cat <<'EOF'
## Summary
- Below `md` (768px): replace three-column resizable layout with single-column document view + left/right Sheet drawers.
- Reuses `RightSidebarContext` for ToC injection — no duplicate route content.
- Tightens prose padding (`px-4` mobile / `px-12` desktop), forces 16px CodeMirror font to block iOS focus-zoom, adds `scroll-padding-top` for ToC anchors under the sticky header.

## Test plan
- [ ] Resize Chrome to 390px: hamburger + ToC trigger appear, resize handles disappear
- [ ] Tap hamburger: files drawer slides in; tap a file: drawer closes, note loads
- [ ] Tap ToC trigger on a note in preview mode: ToC drawer slides in; tap entry: drawer closes, scrolled to heading below header
- [ ] Switch to Edit on mobile: CodeMirror renders, no iOS auto-zoom on focus
- [ ] Reload: both drawers start closed
- [ ] Above 768px: existing desktop layout unchanged
- [ ] `frontend/e2e/mobile.spec.ts` passes in CI

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 3: Wait for CI**

Watch the CI run; if green, request review or self-merge per project policy. Deploy auto-runs on merge to main (per `deploy-fastraid` GitHub Actions job).

---

## Self-review

Spec coverage:

| Spec section | Plan task |
|--------------|-----------|
| `use-media-query.ts` hook | Task 1 |
| `components/ui/sheet.tsx` | Task 2 |
| `mobile-layout.tsx` | Task 3 |
| `app-layout.tsx` branch | Task 4 |
| `note-view.tsx` responsive padding | Task 5 |
| `note-editor.tsx` 16px font | Task 6 |
| `main.css` scroll-padding-top | Task 7 |
| Playwright mobile spec | Task 8 |
| 44px touch targets | Task 3 (`h-11 w-11` on Sheet triggers) |
| `h-dvh` for iOS viewport | Task 3 (root `section` uses `h-dvh`) |
| Drawer starts closed each visit | Task 3 (component-local `useState`, no persistence) + Task 8 spec |
| ToC trigger hidden when no `rightContent` | Task 3 (`{rightContent && <Sheet…>}`) |

Type consistency: `useMediaQuery` returns `boolean` everywhere; `MobileLayout` is the default export consumed by `app-layout.tsx`; the existing `useRightSidebar()` shape is unchanged.

No placeholders; every code block is complete; every command is runnable.

---

Plan complete and saved to `docs/superpowers/plans/2026-05-12-mobile-document-view.md`. Two execution options:

1. **Subagent-Driven (recommended)** — fresh subagent per task, review between tasks, fast iteration.
2. **Inline Execution** — execute tasks in this session, batch with checkpoints.

Which approach?
