# Adopting the shadcn Combobox (Base UI) in the search filter panel

Five traps hit while swapping the search filter panel (`frontend/src/layout/search-panel.tsx`) onto shadcn's Combobox, which is backed by Base UI rather than cmdk. One killed the whole SPA, three are silent, one only CI notices.

## 1. `bun remove` while Vite is running poisons the optimizer permanently

**Symptom:** the entire SPA dies with

```
Failed to fetch dynamically imported module: .../app-shell.ts?t=<stamp>
GET .../app-shell.ts?t=<stamp> 504 (Outdated Optimize Dep)
```

Deterministic across hard reloads. `fetch()` of that exact URL returns **200**, so it reads like a bug in our own module graph.

**Cause** — visible only in `/tmp/saasdev-vite.log`:

```
error while updating dependencies:
Error: ENOENT: no such file or directory, open '.../node_modules/cmdk/dist/index.mjs'
    at prepareRolldownOptimizerRun
```

Vite's optimizer holds its discovered-dep list **in memory**. Adding `@base-ui/react` triggers a re-bundle that walks that list, hits the already-removed `cmdk`, and throws — so every chunk that run should have emitted stays 504 forever.

**Fix:** kill vite, `rm -rf node_modules/.vite/deps`, restart.

**Rules:** any dep add/remove wants a dev-server restart, not an HMR tick. And read `/tmp/saasdev-vite.log` — the browser console only mirrors the client-side symptom.

## 2. `fireEvent.click` never opens a Base UI combobox

**Symptom:** `getAllByRole("option")` throws *"Unable to find an accessible element with the role option"*. The popup is simply never open.

**Cause:** Base UI opens the listbox on `pointerdown` (so it can track a press-drag-release selection gesture). `fireEvent.click` dispatches **only** a click MouseEvent — not the pointerdown/mousedown/mouseup/click sequence a real click produces.

**Fix** — the open helper needs all three:

```ts
fireEvent.pointerDown(input);
fireEvent.mouseDown(input);
fireEvent.click(input);
```

`fireEvent.change` alone does **not** open it either. Open first, then type to narrow.

## 3. `showClear` must be gated on having a value

Passing `showClear` unconditionally renders the X on an empty field (nothing to clear) — and `ComboboxInput`'s input-group hides the chevron trigger whenever a clear button exists in the group:

```
group-has-data-[slot=combobox-clear]/input-group:hidden
```

So the field stops looking like a picker at all. Use `showClear={Boolean(value)}` / `showClear={arr.length > 0}`.

## 4. `multiple` ships only with `ComboboxChips`, and those chips carry their own chrome

`ComboboxChips` has its own border, height and rounding, and no trigger — a multi-select rendered that way looks visibly different from the single-select `ComboboxInput` fields stacked above it.

If visual consistency matters more than in-field chips: keep the shared `ComboboxInput` (it still works with `multiple`) and render selected values as removable chips **below** the field. Selected items stay in the list marked with `ComboboxItem`'s check indicator, so clicking one again toggles it off.

## 5. shadcn CLI output does not pass this repo's biome config

`bunx --bun shadcn@latest add combobox` also writes `input.tsx`, `textarea.tsx`, `input-group.tsx` and touches `button.tsx` (revert `button.tsx` — the only real diff was a `secondary` hover color drift).

CI runs `biome ci .` with `--error-on-warnings` over `src/components/ui/` too, and there are **no suppressions anywhere in that directory**, so vendored files must actually be fixed:

| Class | Handled by |
|---|---|
| formatting, class sorting | `biome check --write --unsafe` |
| `noLeakedRender` — `{cond && (...)}` → `{cond ? (...) : null}` | hand edit |
| a11y rules on `input-group.tsx` | hand edit |

For `input-group.tsx` specifically we:

- dropped `role="group"` from both wrappers — an unnamed group role around ONE control is noise a screen reader must step through;
- deleted the focus-the-input `onClick` on `InputGroupAddon` — a click handler on a static div is a control keyboard users cannot reach, and all it bought was focusing the input when you hit the few pixels of padding around the addon's own button.

## Related

- `frontend-architecture.md` — where the search panel and `components/ui/` live
- `text-to-control-breaks-locators-and-a11y.md` — the sibling failure mode when text becomes a control
