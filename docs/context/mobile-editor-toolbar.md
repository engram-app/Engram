# Mobile editor toolbar (keyboard bar)

The strip of editor actions docked above the on-screen keyboard in the web app:
`frontend/src/viewer/editor/keyboard-bar.tsx`, mounted from `note-page.tsx`.
Four things about it are non-obvious enough that they were each found the hard
way, in the browser, after code that looked right did nothing.

## Gate on FOCUS, never on the keyboard inset

`use-keyboard-inset.ts` measures `innerHeight - (visualViewport.height +
visualViewport.offsetTop)`. That is the keyboard height **only on browsers that
resize just the visual viewport** (iOS Safari, Chrome 108+). Where the LAYOUT
viewport shrinks too — older Chrome, or any page with
`interactive-widget=resizes-content` — `window.innerHeight` drops by the same
amount and the inset is legitimately **0 with the keyboard fully open**.

Gating visibility on a non-zero inset therefore hides the bar outright on
exactly those browsers, which is why it never appeared on a real Android phone
while working fine in the `?keyboard` dev-flag harness. `use-editor-focused.ts`
(document-level `focusin`/`focusout` + `activeElement.closest(".cm-editor")`)
means the same thing everywhere. The inset is used **only to position**;
`bottom-0` with no lift is already correct where the inset reads 0.

## `ySyncFacet(...).undoManager` is a decoy

History belongs to Yjs, not CodeMirror. The editor installs `yCollab` and no
`@codemirror/commands` history, so that package's `undo` finds no history
extension and **silently does nothing**.

The trap is the replacement. `y-codemirror.next` does not export its
`undo`/`redo` from the package root and its `exports` map blocks deep imports,
so the only reachable manager is `view.state.facet(ySyncFacet).undoManager` —
which is typed, documented, and **wrong**: `YSyncConfig`'s constructor mints its
own `Y.UndoManager`, a different instance from the one `yCollab` registers
tracked origins on. Calling `undo()` on it operates on a permanently empty
stack. The button looks correctly wired and is dead.

Run the exported `yUndoManagerKeymap`'s own bindings instead:

```ts
yUndoManagerKeymap.find((b) => b.key === "Mod-z")?.run?.(view);
```

**A stub-based test passes against the decoy.** The original test mocked the
UndoManager and asserted `undo()` was called — green, while the browser did
nothing. `keyboard-bar.test.tsx` now builds a real `yCollab` over a real
`Y.Doc` and asserts the document actually reverts. Seed the `Y.Text` *before*
creating the view: ySync drives the view from the Y doc, so a view created with
content the Y.Text lacks is emptied on the first sync.

## A marker insert maps the caret to the WRONG side by default

CodeMirror maps a caret sitting exactly on an insertion point to *before* the
inserted text. Tapping the list button left the cursor to the left of the `- `,
so the next keystroke landed in front of the bullet. `format-commands.ts`
dispatches line-marker edits through `dispatchKeepingCaretAfterInsert`, which
maps the selection with `assoc = 1`.

Related: `toggleCheckbox` edits **only the marker**, never the whole line.
Rewriting the line wholesale maps the caret to the line start, so tapping the
button mid-word loses your place.

## A programmatic dispatch is not "typing"

CM6's autocompletion activates on transactions it recognises as user input. The
wikilink button dispatches `[[]]` programmatically, so the note picker does not
open by itself — the button would leave you with empty brackets and no list.
Call `startCompletion(view)` after the insert; it runs the same
`wikiCompletionSource` that typing `[[` by hand does, and that source's
`apply()` already handles the closing brackets being there ahead of it
(`alreadyClosed`).

The button itself is just `toggleWrap(view, "[[", "]]")` — two insertions at the
same position, with the caret mapped between them, and a selection wrapped for
free.

## Testing it

happy-dom has no layout engine and no `matchMedia`. The suite stubs
`window.matchMedia` per test (`setViewport("desktop" | "mobile")`) — the shared
`beforeEach` sets mobile, so any test that wants the desktop branch must opt in.
Adding `useMediaQuery` to a component with existing tests silently flips them
all to the mobile branch unless the stub is set.

In a real browser, `?keyboard` on any note URL forces a 300px inset so the bar
can be positioned without a physical keyboard. `KEYBOARD_MIN_PX = 120` keeps a
collapsing mobile address bar from reading as a keyboard.
