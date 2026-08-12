# Mobile editor toolbar (keyboard bar)

The strip of editor actions docked above the on-screen keyboard in the web app:
`frontend/src/viewer/editor/keyboard-bar.tsx`, mounted from `note-page.tsx`.
Several things about it are non-obvious enough that they were each found the
hard way, in the browser, after code that looked right did nothing.

## The visibility gate is NOT the keyboard inset

`use-keyboard-inset.ts` measures `innerHeight - (visualViewport.height +
visualViewport.offsetTop)`. That is the keyboard height **only on browsers that
resize just the visual viewport** (iOS Safari, Chrome 108+). Where the LAYOUT
viewport shrinks too — older Chrome, or any page with
`interactive-widget=resizes-content` — `window.innerHeight` drops by the same
amount and the inset is legitimately **0 with the keyboard fully open**.

Gating visibility on a non-zero inset therefore hides the bar outright on
exactly those browsers, which is why it never appeared on a real Android phone
while working fine in the `?keyboard` dev-flag harness. The inset is used
**only to position**; `bottom-0` with no lift is already correct where it reads
0.

Two conditions gate visibility instead, and both are load-bearing:

1. **Focus** — `use-editor-focused.ts`, a document-level `focusin`/`focusout`
   pair plus `activeElement.closest(".cm-editor")`.
2. **Keyboard actually up** — `useKeyboardOpen()`, which compares the current
   `visualViewport.height` against the tallest height seen *at the current
   width* (keyed by width so a rotation starts a fresh baseline). The viewport
   shrinks under **both** browser models, so this is the one signal that means
   "keyboard" everywhere.

Focus alone was the first implementation and left the bar stranded over the
document whenever the keyboard was dismissed with the platform's own hide
button, which does not blur the editor. `KEYBOARD_MIN_PX = 120` keeps a
collapsing mobile address bar (~60-90px) from reading as a keyboard.

## `touch-action` silently disarms `preventDefault` on pointerdown

The bar keeps the keyboard up by cancelling `pointerdown` on its `nav` — a
press that reaches the document blurs the editor, the keyboard closes, and the
bar unmounts mid-tap.

Making the command row horizontally scrollable broke that guard. `touch-action:
pan-x` is what lets the row pan, and it also makes **pointerdown non-cancelable
for touch** in Chrome: the browser reserves the right to start a scroll, so
`preventDefault()` becomes a no-op. Dragging the row blurred the editor and
closed the keyboard. **Desktop never reproduces this** — mouse `pointerdown` is
always cancelable — so it only shows up on a real phone.

Two layers, because `preventDefault` still works where it *is* cancelable:

1. `useEditorFocused` treats focus inside `[data-editor-toolbar]` as still being
   in the editor, so a pan that lands focus on the bar does not unmount it out
   from under the finger. The keyboard-open gate above is the backstop that
   stops this tolerance from stranding the bar.
2. `pointerup` on the `nav` returns focus to the editor. It is still inside the
   user gesture, which is what allows a programmatic `focus()` to re-open the
   on-screen keyboard.

The general lesson: any `touch-action` value that permits panning makes the
pointerdown guard unreliable. Do not add one without a focus-restore path.

## Other bottom-anchored UI has to be told to move

The setup-checklist FAB is `position: fixed` on the same bottom edge and landed
on top of the toolbar as soon as the keyboard opened. `KeyboardBar` publishes
the space it occupies as the CSS variable `--editor-toolbar-offset` (a
`useLayoutEffect` with no dependency array, so it re-measures whenever the bar
grows a second row), and the FAB clears it with
`bottom-[calc(var(--editor-toolbar-offset,0px)+var(--spacing)*4)]`.

A CSS variable rather than React context: the consumers are unrelated subtrees
that only need a number, and the variable defaults to `0px`, so every other
context is unchanged. **Measured, not a constant** — a hardcoded single-row
height puts the FAB back under the heading picker exactly when it opens.

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

## Headings SET a level, they do not prepend

`toggleLinePrefix(view, "### ")` on an existing `# title` line produces
`### # title`: the line does not start with `### `, so the guard does not fire.
`setHeading(view, level)` replaces the whole existing ATX marker including its
trailing spaces. Tapping the level a line already has removes it — the way back
to plain text without a seventh button.

The `HEADING` regex requires the trailing space CommonMark demands, which is
what keeps `#tag` from reading as an empty h1 and having its hash eaten.

The picker row lives **inside the toolbar `nav`**, not in a portalled popover.
The nav's `onPointerDown` preventDefault is what keeps a tap from blurring the
editor; a portalled row escapes it, drops the keyboard, and unmounts the whole
bar mid-tap.

## Emphasis toggles need the PARSER, not the neighbouring characters

`toggleWrap` unwraps as well as wraps — these are buttons, and a wrap-only
command turns a second tap of "bold" into `****text****`. Deciding whether the
selection is *already* emphasised cannot be done by comparing the characters
on either side, because `*` is a prefix of `**` and string matching is wrong in
**both** directions:

- It reads `**bold**` as italic, so italicising silently downgrades it to
  `*bold*` instead of nesting to `***bold***`.
- A rule patched to avoid that (reject a marker that is part of a longer run)
  then refuses to un-bold `***text***` back down to `*text*`.

`enclosingEmphasis` walks the Lezer tree for an `Emphasis` / `StrongEmphasis` /
`Strikethrough` node containing the selection. The grammar already draws the
distinction; nothing in our code has to.

The one case the parser cannot see is the empty pair that wrapping itself
produces: `**|**` is not emphasis to CommonMark, which requires content. That
one is still matched as literal text, or a second tap doubles it to `****|****`.

**Both test harnesses load `markdown({base: markdownLanguage})`.** Without it
the syntax tree is empty and the emphasis buttons silently only ever wrap —
which is exactly what `keyboard-bar.test.tsx` caught when the parser landed. A
bare `EditorView` is not a valid stand-in for this editor.

## Testing it

happy-dom has no layout engine and no `matchMedia`. The suite stubs
`window.matchMedia` per test (`setViewport("desktop" | "mobile")`) — the shared
`beforeEach` sets mobile, so any test that wants the desktop branch must opt in.
Adding `useMediaQuery` to a component with existing tests silently flips them
all to the mobile branch unless the stub is set.

In a real browser, `?keyboard` on any note URL forces a 300px inset so the bar
can be positioned without a physical keyboard. `KEYBOARD_MIN_PX = 120` keeps a
collapsing mobile address bar from reading as a keyboard.
