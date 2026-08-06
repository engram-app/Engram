# Turning displayed text into a control breaks locators and accessibility

**Trigger:** you replaced a string the UI used to *render as text* with an input, an icon, or any other control — and now an e2e test can't find it, or a screen reader can't read it.

Hit twice in one PR (#1219, the note-header/Properties rework), both times in the same widget, both times silently.

## What actually happens

A string sitting in the DOM as text is legible through three channels at once:

| Channel | Text node | `<input value>` | Icon |
|---|---|---|---|
| Playwright `hasText` / `toHaveText` | yes | **no** | **no** |
| Testing Library `getByText` | yes | **no** | **no** |
| Screen reader | yes | yes (as the field's value) | **no** |

Converting text → control silently drops it out of the channels you were relying on. Nothing errors. The component looks right on screen, which is exactly why this survives review.

### Case 1 — text became an input

The property key was rendered as `<dt>due</dt>`. Making it renameable in place turned it into `<input value="due">`.

```ts
// Could never pass again — an input's value is not text content.
page.getByRole("term").filter({ hasText: key })

// Reads the channel the value actually lives in now.
page.getByRole("textbox", { name: `Rename ${key}` })
```

### Case 2 — text became an icon (the real bug)

The property *type* used to render as the word `text` / `date`. Matching Obsidian meant replacing it with an icon:

```tsx
// The type is now conveyed by pixels ONLY. aria-hidden on the icon, and a
// static name on the button, means AT is told a type picker exists but never
// which type the property already is.
<DropdownMenuTrigger aria-label="Property type">
  <Icon aria-hidden="true" />
</DropdownMenuTrigger>
```

Fix: put the value in the accessible name, which is the one channel that survives the swap.

```tsx
<DropdownMenuTrigger aria-label={`Property type: ${value}`}>
```

That restores the information *and* gives the e2e something honest to assert:

```ts
await expect(typeButton).toHaveAccessibleName("Property type: date");  // not toHaveText
```

## Why the tests didn't catch it

The unit test was named `shows current type and emits a new one on select`. It only ever asserted the **select**. The display half of its own name was never checked, so removing the display broke nothing locally and `e2e-browser` was the first thing to notice — after the PR was already open.

A test whose name claims two behaviours and asserts one is worse than a missing test: it reads as coverage.

## Rules

1. Swapping text for a control? Add or fix an assertion on the **accessible name** in the same commit. It is the only channel that survives text → input → icon.
2. Icon-only controls must carry their *state* in the name, not just their purpose. `"Property type"` names the control; `"Property type: date"` names the control and answers the question the icon was drawn to answer.
3. Prefer `toHaveAccessibleName` over `toHaveText` for anything that might become a control later. `toHaveText` silently encodes "this is a text node" as a contract.
4. When a test comment documents a DOM assumption (`the <dt> text`), treat it as a tripwire — if that sentence stops being true, the test is already wrong.

## Related

- `frontend-architecture.md` — where the viewer components live
- `obsidian-properties-parity.md` — why the type label became an icon in the first place
