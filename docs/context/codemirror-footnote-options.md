# Footnotes in the CM6 editor: build vs adopt

_Researched 2026-09-02. Last verified: 2026-10-03 (`@lezer/markdown` 1.7.2, `@atomic-editor/editor` 0.6.2)._

**Trigger:** you want `[^1]` to render as a superscript in the web editor, or you
are about to add ANY markdown syntax the live-preview editor doesn't know.

## The state today

Reading view renders footnotes correctly (`remark-gfm`, pinned by a test in
`note-view.test.tsx`). The editor does not, in either Edit or Raw:
`grep -i footnote node_modules/@atomic-editor/editor/dist` returns nothing.

The blocker is one level below the editor. Footnotes are not in the parser:

```
@lezer/markdown 1.7.2 GFM bundle
  = Strikethrough, Table, TaskList, Autolink, Superscript, Subscript, Emoji
```

No `Footnote`. So there is **no syntax-tree node to decorate** — any fix needs a
`MarkdownConfig` grammar extension FIRST, then decorations on top. That is two
pieces of work, not one, and it is why "just add a decoration" does not apply.

## What exists publicly (all checked, none adoptable)

| Candidate | Verdict |
|---|---|
| `lezer-markdown-obsidian` (erykwalder) | **Best reference, unusable as a dep.** Has a real `Footnote: MarkdownConfig` — inline `[^1]` + a `FootnoteReferenceParser` LeafBlockParser for `[^1]: def`. MIT. But: depends on `@lezer/markdown ^0.15.5` vs our **1.7.2** (five majors back), last npm publish 2022-05-07, 8 stars, 13 weekly downloads. Installing it pulls a second incompatible parser copy whose node types do not match ours. |
| `lezer-markdown-extensions` (Sec-ant) | Exports only `.` and `./variable`. No footnote. |
| `@lezer/markdown-footnote`, `lezer-markdown-footnote`, `codemirror-footnote` | Do not exist on npm. |
| `@codemirror/lang-markdown` | Exposes no footnote config. |

There is no maintained plug-and-play package. Everyone doing this writes the
`MarkdownConfig` themselves; the Obsidian repo above is the one public worked
example and its LICENSE (MIT) permits adapting the source.

## The third option, which is the interesting one

`@atomic-editor/editor` — the package that owns our live preview — **is open
source and healthy**: `kenforthewin/atomic-editor`, MIT, 135 stars, 5067 weekly
downloads, pushed 2026-08-24, 0.6.2 released 2026-07-11 (we are on latest), 5
open issues, **zero** mentioning footnotes.

So footnote support can go upstream instead of into our tree. That is where it
belongs — Atomic already owns the hide/reveal machinery (`HIDEABLE_SYNTAX`,
`INLINE_MARK_CLASS`, the cursor-inside-link reveal rule) that a footnote
decoration has to cooperate with.

## Recommendation

**Local first, upstream after** — if it gets built at all (see below).

1. Local: a `Footnote` MarkdownConfig passed through the `extensions` array we
   ALREADY use in `live-preview.ts` (`markdown({ extensions: [highlightMarkdown,
   calloutMarker, noParagraphFold] })`), plus a decoration plugin mirroring
   `editor/callout-decoration.ts`. That combination — custom grammar node +
   sibling decoration — is a pattern this repo has already proven twice
   (callouts, KaTeX). Roughly 40 lines of grammar (adapt the MIT reference) and
   ~80 of decoration, plus tests.
2. Then offer the same to `kenforthewin/atomic-editor`, so we stop carrying it.

Do NOT add `lezer-markdown-obsidian` as a dependency. Read it, credit it.

### Trap if you do build it

`MarkdownParser.configure` silently SKIPS a `defineNodes` entry whose name
already exists (`if (nodeTypes.some(t => t.name == name)) continue`). If Atomic
later ships its own `Footnote` node, ours goes quiet rather than erroring, and
the symptom is "footnotes stopped rendering after a dep bump" with nothing in
the diff. Name-collide deliberately or watch for it on upgrade.

## Is it worth building?

Probably not yet. Nothing in the product generates footnotes and no user has
asked. The seeded welcome note deliberately uses none
(`lib/engram/vaults/welcome_note.ex`), and the reference-panel blurb tells
users footnotes are reading-view only. Revisit when a real note needs one.
