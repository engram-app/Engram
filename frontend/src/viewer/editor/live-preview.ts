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
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import type { Extension } from "@codemirror/state";

export interface LivePreviewOpts {
	resolveWikiLink: (name: string) => string;
}

/**
 * The Rendered-mode decoration layer. Pure CM6 extensions (view-only): they
 * decorate the markdown source but never mutate EditorState.doc, so the yCollab
 * Y.Text binding (see note-editor.tsx) is untouched. Wire wikilinks to our SPA
 * routes; the click-to-open navigation is a hard `window.location` nav, matching
 * the plain `<a href>` wikilinks already rendered in Reading mode (note-view.tsx
 * hrefTemplate) rather than a router push. Callouts/KaTeX are added in Task 6 as
 * sibling extensions.
 */
export function livePreviewExtensions(opts: LivePreviewOpts): Extension[] {
	return [
		markdown({ base: markdownLanguage, extensions: [highlightMarkdown] }),
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
				window.location.assign(opts.resolveWikiLink(target));
			},
		}),
	];
}
