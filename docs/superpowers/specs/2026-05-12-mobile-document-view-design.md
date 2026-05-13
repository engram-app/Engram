# Mobile-friendly document view — design

## Context

Desktop document view is a three-column `ResizablePanelGroup`: file picker (left), document body + Edit/Preview tabs (center), "On this page" ToC (right). Below ~768px the three columns become unusable: panels can't shrink below their min sizes, the resize handles are not touch-friendly, and the prose padding (`px-12`) plus `prose-lg` typography leaves no room for content.

Goal: deliver an equally-capable read + edit experience below `md` (`768px`), reusing shadcn primitives, without forking the desktop flow.

User intent confirmed during brainstorming: **equal read + edit** on mobile. ToC and file picker reachable in one tap. Editor must be usable on a touch keyboard.

## Architecture

A single media-query branch in `app-layout.tsx` swaps the panel layout for a drawer layout below `md`. Both modes share:

- The same `<Outlet/>` (document/editor) — no duplicated route content
- The same `RightSidebarContext` (ToC injection from `note-page.tsx` is unchanged)
- The same auth, theme, vault state

Above `md`: current `ResizablePanelGroup` with `autoSaveId="engram:app-layout"`.

Below `md`:

```
┌─────────────────────────────────┐
│ ☰   <title · vault>      ⋮  ⊟ │  sticky header, h-12
├─────────────────────────────────┤
│  [Preview]      [Edit]          │  shadcn Tabs, full-width
├─────────────────────────────────┤
│                                 │
│   document or CodeMirror        │
│                                 │
│   prose (not prose-lg)          │
│   px-4 (not px-12)              │
│                                 │
└─────────────────────────────────┘
```

- ☰ left trigger opens a `Sheet side="left"` carrying the existing `VaultSwitcher` + file tree
- ⊟ right trigger opens a `Sheet side="right"` carrying `<NoteToc>` (only rendered when `rightContent != null`; hidden when no ToC is available, e.g. on Settings)
- Both drawers **start closed on every navigation** — open state is component-local, not persisted (matches user direction)
- Floating "expand" buttons from desktop are hidden below `md`; the drawer triggers replace them

## Components

| Component | Status | Purpose |
|-----------|--------|---------|
| `layout/app-layout.tsx` | modify | Branch on `useMediaQuery('(min-width: 768px)')`; render desktop panels or `MobileLayout` |
| `layout/mobile-layout.tsx` | **new** | Sticky header (hamburger + title + user menu + ToC trigger), `<Outlet/>`, two `Sheet`s |
| `components/ui/sheet.tsx` | **new** | shadcn primitive (`bunx --bun shadcn@latest add sheet`) |
| `hooks/use-media-query.ts` | **new** | Tiny `window.matchMedia` hook (~20 LOC) with SSR-safe default and listener cleanup |
| `viewer/note-view.tsx` | modify | Responsive padding (`px-4 sm:px-8 lg:px-12`) and typography (`prose lg:prose-lg`); `scroll-margin-top` already covered by CSS |
| `viewer/note-editor.tsx` | modify | CodeMirror theme extension forcing `font-size: 16px` on `.cm-content` to prevent iOS focus-zoom; ensure `EditorView.lineWrapping` stays on (already is) |
| `main.css` | modify | `html { scroll-padding-top: 4rem }` for ToC anchor jumps under sticky header |
| `layout/right-sidebar-context.tsx` | no change | Already exposes `content` and `setContent`; mobile reads `content` to decide whether to render the right drawer trigger |

## Data flow

Unchanged from desktop. `note-page.tsx` continues to `setRightContent(<NoteToc/>)` when in preview mode. The mobile `Sheet` renders that same node inside its `SheetContent`.

The desktop right panel currently collapses/expands via `rightRef.current?.collapse()` based on `rightContent`. On mobile there is no panel — the trigger button is conditionally rendered (`{rightContent && <SheetTrigger.../>}`) and the `Sheet`'s `open` state lives in `MobileLayout`'s local `useState`.

## Touch + viewport fixes

| Concern | Fix |
|---------|-----|
| iOS auto-zoom on editor focus | CodeMirror theme extension: `'.cm-content': { fontSize: '16px' }` |
| 100vh ≠ visible viewport on iOS | Replace `h-screen` with `h-dvh` on app shell root |
| ToC anchor under sticky header | `html { scroll-padding-top: 4rem }` |
| Touch target size | shadcn default `size="icon"` button is 36px. Header icon buttons get `h-11 w-11` (44px) class override on mobile |
| Drawer dismissal | Radix Dialog handles backdrop tap + Esc. Swipe-to-dismiss deferred (would need `vaul` dep) |
| Soft keyboard hides caret | CodeMirror handles via `scrollIntoView` on selection change by default — verify in testing; if broken, add `EditorView.scrollMargins` |

## Breakpoint choice

`md` (768px) is the Tailwind default and the natural break between phone and tablet. Tablets in portrait (~768–1024px) get the desktop panel layout — usable because tablets have room for three narrow columns and a stylus/touchpad. iPad Mini in portrait (744px) lands on mobile mode; acceptable given thumb-reach concerns.

## Out of scope

- Swipe-between-notes gesture
- Bottom-tab navigation pattern (rejected during brainstorm: steals vertical space, breaks parity with desktop two-sidebar mental model)
- Persisting drawer state across sessions (rejected by user: "restart on close")
- PWA install prompt + offline service worker (separate spec)
- `vaul` swipe-to-dismiss

## Testing

- Unit: `use-media-query.ts` — SSR default, listener attach/detach, change events
- Playwright: extend `frontend/e2e/` with a mobile viewport spec (`page.setViewportSize({ width: 390, height: 844 })`) that:
  1. Opens a note, asserts ToC drawer trigger is visible
  2. Taps trigger, asserts ToC drawer opens
  3. Taps a ToC entry, asserts drawer closes and page scrolls
  4. Taps hamburger, asserts file drawer opens
  5. Switches to Edit tab, asserts CodeMirror renders and is focusable
- Manual: iOS Safari + Android Chrome smoke test of the editor (font-size zoom, caret visibility, keyboard overlap)

## Verification checklist

1. `cd frontend && bun install` then `bun run dev`
2. Resize browser below 768px: layout flips to drawer mode; resize handles disappear; padding tightens
3. Open a note: ToC trigger appears in header; tap reveals drawer with same content as desktop right panel
4. Navigate to Settings: ToC trigger hidden (no `rightContent`)
5. Tap Edit: CodeMirror loads, font is 16px+ on iOS, no page zoom
6. Reload page on mobile: drawers start closed regardless of last state
7. `bun run build`: clean TypeScript, no new warnings
8. Playwright mobile spec passes locally and in CI
