# Context Doc: CodeMirror live-preview extensions (`src/viewer/editor/`)

_Last verified: 2026-07-30_

## Status

Working. Everything below shipped in PR #1142.

## What This Is

The traps you hit writing our own CM6 decorations on top of
`@atomic-editor/editor`, which is what renders Rendered mode. Two of them cost
real time and neither is findable in anyone's docs.

## Environment

`frontend/`, CodeMirror 6 via `@codemirror/lang-markdown` (→ `@lezer/markdown`),
`@atomic-editor/editor` v0.6.2. Applies to Rendered mode only; Reading mode is
react-markdown/remark and shares nothing with this.

## Gotchas

### 1. Lezer parses `[!type]` as a Link, and that is what mangled callout headers

CommonMark has no callouts. `[!important]` is a **shortcut reference link** —
`[text]` whose definition is presumed to be elsewhere — and lezer emits a `Link`
node **whether or not any definition exists**.

Atomic's `inlinePreview` then treats it like any link: link colour, a link icon
after the `]`, and a replace decoration over the `[` and `]` so the syntax gets
out of the way. On a callout header that means an icon pointing at nothing, and
a revealed header reading `> !important Title` — the brackets you came to edit
are hidden.

It is invisible unless the header is **revealed**. Once the caret leaves,
`callout-decoration.ts` replaces the whole line with icon + title and paints
over the damage, which is why it shipped unnoticed.

Fix lives in `src/viewer/editor/callout-marker.ts`: a `parseInline` rule
installed `before: "Link"` that claims `[!type]` at the start of an inline
section and emits its own `CalloutMarker` node. No `Link` node means nothing
downstream has anything to act on.

### 2. One highlight tag serves many node types — check before overriding

`tags.processingInstruction` is what lezer gives **HeaderMark, HardBreak,
QuoteMark, ListMark, LinkMark, EmphasisMark, CodeMark and TableDelimiter**, from
one line of its grammar. A `Prec.highest` `syntaxHighlighting` rule naming that
tag repaints **every syntax mark in the editor**, not just yours.

Use `tags.special(tags.processingInstruction)` for a node you want to style
alone. A rule can name the variant specifically, and it still falls back to the
plain tag for rules that do not.

The same trap in the other direction, already fixed in `live-preview.ts`:
`atomicMarkdownSyntax` maps `t.monospace` to `--atomic-editor-link`, the same
variable as `t.link` and `t.url`. That is why every inline `code` and the whole
body of any unparseable fence (```` ```dataview ````) rendered purple. One
variable, two meanings — it cannot be split by setting a token, only by a
highlight style that wins.

**How to check:** `grep -n "yourTag" node_modules/@lezer/markdown/dist/index.js`
before you write the rule.

### 3. `syntaxTree(state)` is lazy — do not use it for whole-document decorations

Measured: on a freshly created `EditorState` for a 40-character document, the
tree covered **7 characters** (`Document[0,7]`, `Paragraph[0,6]`). In a live
editor it trails the viewport on a long note.

For a decoration `StateField` that must find every match in the document, that
means anything below the parse frontier **silently stops rendering**. That is a
worse failure than whatever the tree was going to fix.

`ensureSyntaxTree(state, doc.length, timeout)` is not a fix either: it stalls on
long documents and returns `null` on timeout, leaving the same gap.

### 4. Block-replace decorations must come from a StateField, and must span whole lines

CM6 rejects a replace decoration spanning a line break if it comes from a
`ViewPlugin`, and only enforces it at view-update time — so a unit test that
merely builds the state will not catch it. `mermaid-decoration.test.ts` and
`katex-decoration.test.ts` both dispatch an update specifically to hit the check.

`block: true` also requires the range to cover entire lines. An indented fence
starts at its backticks, so snap `from`/`to` with `doc.lineAt()`.

## Failed Approaches / Dead Ends

- **A counter-decoration to undo Atomic's link treatment.** There isn't one. A
  replace decoration cannot be un-replaced by a later extension at any
  precedence, and CM6 gives you no way to filter another extension's ranges out
  of the `EditorView.decorations` facet. `inlinePreview`'s only config is
  `onLinkClick`; its `LINK_CHILD_SYNTAX` / `INLINE_MARK_CLASS` tables are
  module-private. If Atomic's behaviour is wrong for our syntax, the only place
  to intervene is **upstream of the parse**.
- **`syntaxTree(state)` for the mermaid fence scan.** Written, tested, reverted —
  see gotcha 3. Replaced with a fence-aware O(lines) scan: a closing fence must
  have at least as many backticks as its opener, and the scan jumps past **every**
  fence it finds whether or not it is mermaid. That is what stops a ```` ```mermaid ````
  line quoted inside a ```` ````markdown ```` block from being read as a real one, and
  allowing 0-3 leading spaces is what makes a fence inside a list item render.
- **`Prec.highest` on `calloutDecoration` was tried as a StateField conversion
  first.** Converting it did not fix the vanishing callout title; the precedence
  wrapper did. The overlap with `inlinePreview` is the cause, not the decoration
  source.

## Key Commands / Patterns

```bash
# Which node types share a highlight tag
grep -n "processingInstruction" node_modules/@lezer/markdown/dist/index.js

# What Atomic actually does with a node type
grep -n "atomic-link\|HIDEABLE_SYNTAX" node_modules/@atomic-editor/editor/dist/inline-preview.js

# Dump a parse tree to check an assumption instead of reasoning about it
#   syntaxTree(state).iterate({ enter: (n) => out.push(`${n.name}[${n.from},${n.to}]`) })
```

Diagnosing in the browser beat reasoning about the code every time. Read the
computed style / decoration set on the real element: two nodes coming back with
the **identical highlight class** is what proved gotcha 2, and a line whose
`textContent` had lost its brackets is what proved gotcha 1.

## References

- `frontend/src/viewer/editor/callout-marker.ts` — the parse-level fix
- `frontend/src/viewer/editor/live-preview.ts` — `syntaxOverrides`, extension order
- `frontend/src/viewer/editor/mermaid-decoration.ts` — the fence scanner and why it is not tree-based
- `frontend/src/viewer/editor/decoration-utils.ts` — `selectionTouches`, the shared reveal rule
- `docs/context/frontend-architecture.md` — where the editor sits in the SPA
- PR #1142
