import { codeFolding, foldGutter, foldKeymap, foldNodeProp } from "@codemirror/language";
import type { MarkdownConfig } from "@lezer/markdown";
import type { Extension } from "@codemirror/state";
import { type EditorView, keymap, ViewPlugin } from "@codemirror/view";

/**
 * Obsidian-style collapsible headings.
 *
 * The FOLD LOGIC is not ours and is not new: `@codemirror/lang-markdown`
 * already registers a `foldService` (`headerIndent`) that resolves a heading
 * and folds from the end of its line to the end of its section, plus a
 * `foldNodeProp` covering fenced code and blockquotes. That service ships
 * inside the support array `markdown()` returns, so it has been live in both
 * Edit and Raw the whole time — with no UI mounted to reach it.
 *
 * This adds only that UI. `foldGutter` is a real gutter (a column, not an
 * inline widget) — CodeMirror has no inline equivalent, and Obsidian's arrow
 * is likewise a gutter that is simply invisible until you hover the editor.
 * obsidian-theme.css does that half: zero-width-looking, transparent, markers
 * revealed on hover. A folded line keeps its marker at all times, because an
 * arrow you can only find by hovering is a fine way to fold and a terrible way
 * to discover you can unfold.
 */

/**
 * Stops PARAGRAPHS being foldable.
 *
 * `lang-markdown`'s `foldNodeProp` marks every Block that is not a Document,
 * heading or list as foldable — which includes Paragraph, so any paragraph
 * running to two or more lines grew its own fold arrow. Obsidian folds
 * headings, lists and code, never a paragraph, and a chevron beside every
 * wrapped paragraph is pure noise on hover.
 *
 * Returning null from the fold function means "not foldable". Must be passed
 * to BOTH `markdown()` calls (live-preview's and raw mode's): props are
 * applied by `nodeSet.extend` in configure order, so this only overrides the
 * parser it is actually handed to.
 */
export const noParagraphFold: MarkdownConfig = {
	props: [foldNodeProp.add({ Paragraph: () => null })],
};

/** Chevron matching the tree's disclosure triangles, rotated when open. */
function chevron(open: boolean): HTMLElement {
	const span = document.createElement("span");
	span.className = `cm-fold-chevron${open ? " cm-fold-chevron-open" : ""}`;
	// Inline SVG rather than a text glyph: "⌄" and "›" render at wildly
	// different weights across the fonts this editor runs in.
	span.innerHTML =
		'<svg viewBox="0 0 24 24" width="12" height="12" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="m9 18 6-6-6-6"/></svg>';
	span.setAttribute("aria-label", open ? "Collapse section" : "Expand section");
	return span;
}

/**
 * Reveals the fold arrow for the ROW under the pointer, not the whole editor.
 *
 * Needed because the arrow lives in the gutter — a separate column, a sibling
 * of `.cm-content` — so no CSS selector reaches it from the hovered
 * `.cm-line`. `.cm-editor:hover` lights every arrow at once, which reads as
 * chrome; Obsidian shows exactly the one you are pointing at.
 *
 * Matches on vertical position rather than any CodeMirror internal: a gutter
 * element and its line occupy the same row by construction, and foldGutter
 * owns the elements themselves (we never re-render them).
 */
const HOVER_CLASS = "cm-fold-row-hover";

const foldHoverSync = ViewPlugin.fromClass(
	class {
		private hovered: Element | null = null;

		constructor(private readonly view: EditorView) {
			this.view.dom.addEventListener("mousemove", this.onMove);
			this.view.dom.addEventListener("mouseleave", this.clear);
		}

		private readonly onMove = (event: MouseEvent) => {
			const gutter = this.view.dom.querySelector(".cm-foldGutter");
			if (!gutter) {
				return;
			}
			const row =
				[...gutter.querySelectorAll(".cm-gutterElement")].find((el) => {
					const r = el.getBoundingClientRect();
					return event.clientY >= r.top && event.clientY <= r.bottom;
				}) ?? null;
			if (row === this.hovered) {
				return;
			}
			this.hovered?.classList.remove(HOVER_CLASS);
			row?.classList.add(HOVER_CLASS);
			this.hovered = row;
		};

		private readonly clear = () => {
			this.hovered?.classList.remove(HOVER_CLASS);
			this.hovered = null;
		};

		destroy() {
			this.view.dom.removeEventListener("mousemove", this.onMove);
			this.view.dom.removeEventListener("mouseleave", this.clear);
			this.clear();
		}
	},
);

export const headingFold: Extension = [
	codeFolding({
		placeholderDOM(_view, onclick) {
			const el = document.createElement("span");
			el.className = "cm-foldPlaceholder";
			el.textContent = "…";
			el.title = "Expand section";
			el.setAttribute("aria-label", "Expand section");
			el.onclick = onclick;
			return el;
		},
	}),
	foldGutter({ markerDOM: chevron }),
	foldHoverSync,
	keymap.of(foldKeymap),
];
