import {
	atomicEditorTheme,
	atomicMarkdownSyntax,
	highlightMarkdown,
	imageBlocks,
	inlinePreview,
	tables,
	wikiLinks,
} from "@atomic-editor/editor";
// Atomic ships decoration CSS separately; import once so widgets render.
import "@atomic-editor/editor/styles.css";
// Obsidian-default palette: set Atomic's CSS vars per theme (must come AFTER
// the Atomic stylesheet so our values win the cascade).
import "./obsidian-theme.css";
// Nested-blockquote depth rendering (Atomic renders `>` flat). Load after
// Atomic's stylesheet so the depth-aware rules win the cascade.
import "./blockquote-depth.css";
import { ATOMIC_CODE_LANGUAGES } from "@atomic-editor/editor/code-languages";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { HighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { type Extension, Prec } from "@codemirror/state";
import { tags } from "@lezer/highlight";
import { getAppRouter } from "../../router";
import { blockquoteDepthPlugin } from "./blockquote-depth";
import { calloutDecoration } from "./callout-decoration";
import { calloutMarker } from "./callout-marker";
import { katexDecoration } from "./katex-decoration";
import { mermaidDecoration, mermaidKeymap } from "./mermaid-decoration";

/**
 * Token colours that must beat atomicMarkdownSyntax.
 *
 * MONOSPACE: repainted as body text.
 *
 * atomicMarkdownSyntax maps `t.monospace` to --atomic-editor-link, the SAME
 * token it uses for t.link and t.url. That makes every scrap of code purple:
 * inline `code`, and the entire body of any fence whose language we cannot
 * parse (```dataview being the one that surfaced it). One variable serving two
 * meanings, so it cannot be split by setting a token — it needs a highlight
 * style that wins.
 *
 * Body colour is the right answer rather than a third hue, because Reading mode
 * already renders inline code with no colour of its own: it takes a background
 * chip and inherits the text colour. This makes the panes agree again.
 *
 * SPECIAL PROCESSING INSTRUCTION: the `[!type]` callout marker (see
 * callout-marker.ts). Faint, because on a revealed callout header it is the one
 * part of the line that is syntax rather than the title you came to edit.
 * special(), not the bare tag — lezer hands plain processingInstruction to every
 * syntax mark it knows (HeaderMark, QuoteMark, ListMark, LinkMark, …), so
 * targeting it here would repaint all of them.
 */
const syntaxOverrides = HighlightStyle.define([
	{ tag: tags.monospace, color: "var(--atomic-editor-fg)" },
	{ tag: tags.special(tags.processingInstruction), color: "var(--atomic-editor-fg-faint)" },
]);

export interface LivePreviewOpts {
	resolveWikiLink: (name: string) => string;
}

/**
 * The Rendered-mode decoration layer. Pure CM6 extensions (view-only): they
 * decorate the markdown source but never mutate EditorState.doc, so the yCollab
 * Y.Text binding (see note-editor.tsx) is untouched. Wikilinks resolve through
 * the same `/:slug/wiki/*` route as Reading mode (resolveWikiLink is NotePage's
 * wikiHref closure); click-to-open navigates via the app router — a hard
 * `window.location` nav here full-page-reloaded the SPA on every editor-mode
 * link hop. Callouts/KaTeX are sibling view-only decoration extensions (see
 * callout-decoration.ts, katex-decoration.ts).
 */
export function livePreviewExtensions(opts: LivePreviewOpts): Extension[] {
	return [
		// codeLanguages is what makes a fenced block highlight as its LANGUAGE.
		// Without it lang-markdown never parses the fence body, so ```ts rendered
		// as undifferentiated code text in the editor while Reading mode (which
		// highlights via rehype-highlight) coloured it — the same note looked
		// different per pane. ATOMIC_CODE_LANGUAGES is the curated 21-language list
		// the editor package ships for exactly this; every grammar sits behind a
		// dynamic import, so they stay lazy chunks rather than eager bundle weight.
		markdown({
			base: markdownLanguage,
			codeLanguages: ATOMIC_CODE_LANGUAGES,
			// calloutMarker must come before Link in the inline parser list, which
			// it declares itself; order here is irrelevant.
			extensions: [highlightMarkdown, calloutMarker],
		}),
		// See syntaxOverrides above — two tags, both overriding atomicMarkdownSyntax.
		Prec.highest(syntaxHighlighting(syntaxOverrides)),
		// Applies the syntax-highlight *colors* for the markdown grammar tags
		// `highlightMarkdown` adds (headings, emphasis, etc). Without this the
		// live-preview text renders unstyled — atomicEditorTheme alone only sets
		// layout/surface colors, not per-token highlighting.
		atomicMarkdownSyntax,
		atomicEditorTheme,
		tables({}),
		imageBlocks(),
		inlinePreview({}),
		wikiLinks({
			// Atomic's `resolve` is async and returns a display target, not a
			// plain string like our `resolveWikiLink` — wrap it. We have no
			// existence check, so every link resolves (status "resolved");
			// `label` stays the raw wikilink text.
			resolve: (target) => Promise.resolve({ target: opts.resolveWikiLink(target), label: target }),
			onOpen: (target) => {
				const href = opts.resolveWikiLink(target);
				if (href.startsWith("/")) {
					void getAppRouter().navigate(href);
				} else if (href.startsWith("#")) {
					// Same-page heading link — hash assignment scrolls, no reload.
					window.location.hash = href;
				}
			},
		}),
		// Prec.highest is load-bearing, not tidiness. A callout's header line is
		// replaced wholesale by our icon+title widget, and inlinePreview emits its
		// own replace over the QuoteMark on that same line. At equal precedence
		// Atomic's won and ours was silently dropped — but only on a rebuild AFTER
		// the first, so a callout rendered correctly until you put the caret in it,
		// and arrowing back out left the header line completely blank. The widget
		// was in the decoration set the whole time; it just lost the overlap.
		Prec.highest(calloutDecoration),
		katexDecoration,
		// Atomic has no mermaid support of its own, so ```mermaid stayed raw text
		// in the editor while Reading mode drew the diagram. Ours, like the two
		// above: a view-only widget that reveals its source on cursor entry.
		mermaidDecoration,
		// Lets ArrowUp/Down enter a rendered diagram instead of stepping over it.
		// A block replace has no position inside it for the caret to land on, so
		// without this the block is reachable only by clicking.
		mermaidKeymap,
		blockquoteDepthPlugin,
	];
}
