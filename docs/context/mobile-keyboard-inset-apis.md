# Positioning UI above the mobile keyboard: which API, and what we already ship

Researched 2026-08-02 while deciding where the formatting toolbar should live
on mobile. Written down because the obvious-looking API is the wrong bet, and
because we already ship one of the three without it being obvious what it does
or does not cover.

## The three mechanisms

| | Venue | Status | Chromium | Firefox | Safari / iOS |
|---|---|---|---|---|---|
| `interactive-widget` viewport meta key | W3C CSSWG, css-viewport-1 | **standards track** (WD) | yes | implementing (bugzilla 1831649) | **no** — webkit 259770 |
| `navigator.virtualKeyboard` + `env(keyboard-inset-*)` | WICG incubation | **not standards track** | yes | no signal | **no** — webkit 230225 |
| `window.visualViewport` | WHATWG HTML + css-viewport-1 | living standard | yes | yes | **yes** |

Spec: <https://drafts.csswg.org/css-viewport-1/#interactive-widget-section>

**Do not build on `navigator.virtualKeyboard`.** It reads like the clean
declarative answer — set `overlaysContent = true`, then
`bottom: env(keyboard-inset-height, 0px)` — but it is a WICG incubation that
neither Apple nor Mozilla has committed to. Both point at the CSSWG viewport
key instead. The `keyboard-inset-*` env vars are defined by that same
incubation, so they inherit its support story.

**WebKit status, checked 2026-08-02.** Bug 259770 (`interactive-widget`) was
filed 2023-08-03 and is still `NEW` and unassigned, with pings in 2025-03,
2026-01, 2026-02, 2026-04 and 2026-06 and no Apple response. Bug 230225
(VirtualKeyboard API) is likewise `NEW`. Re-check before assuming either has
landed; nothing about iOS below is safe to assume forward.

## What we already ship

`frontend/index.html`:

```html
<meta name="viewport" content="width=device-width, initial-scale=1.0, interactive-widget=resizes-content" />
```

Added in `d4eaa43c` (#663, "mobile UI polish") for the onboarding flow, whose
commit message reads "auth shell/layout use h-dvh + viewport interactive-widget
fix so the mobile keyboard no longer overlaps inputs".

That is two fixes, and they do **not** split evenly:

- `interactive-widget=resizes-content` — Chromium only. Inert on iOS.
- `h-dvh` — everywhere.

So the on-device iOS verification in that PR was carried by `h-dvh`. Do not
read the meta tag as evidence that keyboard overlap is handled on iOS.

Nothing else in the codebase touches any of the three: no `visualViewport`, no
`navigator.virtualKeyboard`, and the Obsidian plugin has none of them.

## The interaction worth knowing

`resizes-content` makes the keyboard shrink the **layout** viewport, not just
the visual one. Consequences:

- **Android**: `position: fixed; bottom: 0` already sits above the keyboard.
  No JavaScript needed.
- **iOS**: layout viewport is untouched, so a fixed-bottom element stays
  behind the keyboard. Needs the `visualViewport` fallback.

The usual iOS fallback measures the keyboard indirectly:

```js
const inset = Math.max(0, window.innerHeight - (visualViewport.height + visualViewport.offsetTop));
el.style.transform = `translateY(-${inset}px)`;
```

**This composes correctly with our meta tag rather than fighting it.** On
Android `innerHeight` shrinks in step with `visualViewport.height`, so `inset`
computes to ~0 and no transform is applied — correct, because the layout
already moved. On iOS `innerHeight` is unchanged, so `inset` is the real
keyboard height. One code path, right on both, *because* of
`resizes-content`. If someone ever changes that value to `resizes-visual` or
`overlays-content`, this formula starts double-counting on Android.

## Gotchas for a format toolbar specifically

Different from the usual chat-composer case:

1. **Buttons must not take focus.** Tapping Bold with a focusable button
   dismisses the keyboard and drops the selection. Needs
   `onPointerDown={e => e.preventDefault()}` per button.
   `viewer/editor/toolbar.tsx` does **not** do this today — it never mattered
   while the toolbar was docked under the header.
2. **`visualViewport` also fires on pinch-zoom**, so an unguarded handler
   slides the toolbar around during an ordinary zoom. Gate on the editor
   actually having focus.
3. **Listen to `scroll` as well as `resize`.** iOS auto-scrolls the caret into
   view, which changes `offsetTop` without firing a resize.
4. Combine with `env(safe-area-inset-bottom)` so the toolbar clears the home
   indicator when the keyboard is closed.
