# A Radix menu item that opens an inline editor needs `modal={false}`

Found building the note-page kebab (`frontend/src/viewer/note-menu.tsx`). The
"Rename" item set state that mounts `RenameInput` in the inline title, and the
rename box vanished in the same tick it appeared — no error, no failed
mutation, just a menu that appeared to do nothing.

## The mechanism

`DropdownMenu` defaults to `modal={true}`, which wraps the content in a Radix
`FocusScope` with `trapped`. The trap listens for focus leaving the menu and
forces it back in.

The order that kills you:

1. Click the item → `onSelect` → `setRenamingFor(id)`, and Radix begins closing.
2. React commits: `RenameInput` mounts and its mount effect calls `el.focus()`.
3. The **still-mounted** focus trap sees focus land outside the menu and yanks
   it back.
4. That yank blurs the input. `RenameInput` has `commitOnBlur` and settles
   commit-or-cancel on blur, so it calls `onCancel` → `setRenamingFor(null)`.

The box is gone before a human could see it. Nothing throws; the value was
unchanged so `onCancel` fires rather than `onCommit`, and no mutation runs to
leave a trace.

## The fix

```tsx
<DropdownMenu modal={false}>
```

That is the whole fix. A kebab has no reason to trap focus or lock background
scroll.

## What does NOT fix it

`onCloseAutoFocus={(e) => e.preventDefault()}` on `DropdownMenuContent`. That
is the usual advice for "the menu steals focus back on close", and it is
answering a different question — the yank here happens while the menu is still
open, not during its close-time focus restore. Prop forwarding is fine (the
shadcn wrapper spreads `...props` onto `DropdownMenuPrimitive.Content`); it
just addresses the wrong moment. Tested: it leaves the bug in place, and
`modal={false}` alone is sufficient without it.

## The general shape

Any Radix overlay defaulting to modal + any input that mutates state on blur =
this bug. In this repo the blur-committing input is `RenameInput`
(`frontend/src/viewer/tree-actions/rename-input.tsx`), whose `commitOnBlur` is
opt-in precisely because the two callers want opposite things. If a future menu
item opens that box — or any autofocusing surface that is not itself a Radix
overlay — it needs the same `modal={false}`.

Radix dialogs are exempt: they mount their own focus scope, so the outgoing
menu's trap has somewhere legitimate to hand off to. The move and delete
actions in the same kebab never showed the bug for that reason.

## Regression test

`frontend/src/viewer/note-page.test.tsx` → `kebab > starts a rename from the
menu`. It fails if `modal` goes back to its default. Note it only catches this
because the test asserts the textbox is present *synchronously* after the
click; an `await findBy...` would race the same teardown and could pass by
accident.
