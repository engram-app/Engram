import { syntaxTree } from "@codemirror/language";
import { StateEffect } from "@codemirror/state";
import { Decoration, EditorView, WidgetType } from "@codemirror/view";
import type { SyntaxNode, Tree } from "@lezer/common";
import type { Translate } from "@/i18n/translate";
import { fenceSurvives, scanFenced } from "./fence-scan";
import { defineRenderer, type TextRenderer } from "./render-core";
import { translator } from "./translator";

interface AttachmentEmbedOpts {
	/** Embed target (`pic.png`, `img/pic.png`) to the attachment's vault path, or null. */
	resolve: (target: string) => string | null;
	/** Authenticated fetch of the attachment bytes, as an object URL. */
	load: (path: string) => Promise<string>;
}

const IMAGE = /\.(?:png|jpe?g|gif|webp|svg|avif|bmp)$/iu;
const EMBED = /!\[\[(?<target>[^\]|]+)(?:\|(?<alias>[^\]]*))?\]\]/gu;

class EmbedWidget extends WidgetType {
	constructor(
		private readonly path: string,
		private readonly alt: string,
		private readonly width: number | null,
		private readonly load: AttachmentEmbedOpts["load"],
		private readonly t: Translate,
	) {
		super();
	}

	eq(other: EmbedWidget) {
		return (
			other.path === this.path &&
			other.alt === this.alt &&
			other.width === this.width &&
			other.t === this.t
		);
	}

	toDOM(view: EditorView) {
		const wrap = document.createElement("span");
		wrap.className = "cm-attachment-embed";
		if (this.width !== null) {
			wrap.style.width = `${this.width}px`;
		}
		this.load(this.path)
			.then((src) => {
				const img = document.createElement("img");
				img.src = src;
				img.alt = this.alt;
				// Chrome reports a dragged <img> as a file drag; without this, dragging an
				// embed would look like an OS file drop and re-upload it.
				img.draggable = false;
				img.addEventListener("load", () => view.requestMeasure());
				wrap.replaceChildren(img);
				view.requestMeasure();
			})
			.catch(() => {
				wrap.classList.add("cm-attachment-embed-error");
				const { t } = this;
				wrap.textContent = t("Couldn't load {path}", { path: this.path });
				view.requestMeasure();
			});
		return wrap;
	}

	// Inert content: let presses through so the caret lands and reveals the source.
	ignoreEvent() {
		return false;
	}
}

const CODE_NODES = new Set(["CodeBlock", "FencedCode", "InlineCode"]);

/** Is `pos` inside code (indented block, fence or `inline`)? Code is literal, so no embed there. */
function inCode(tree: Tree, pos: number): boolean {
	for (let n: SyntaxNode | null = tree.resolveInner(pos, 1); n; n = n.parent) {
		if (CODE_NODES.has(n.name)) {
			return true;
		}
	}
	return false;
}

/** A `![[target|alias]]` embed, or a fenced block (no embeds inside, no decoration). */
type EmbedToken = { target: string; alias: string } | null;

/**
 * Obsidian-style image embeds: `![[pic.png]]` renders as the image, and the raw
 * source comes back while the caret is on it. View-only (never edits the doc).
 * Images only; other embeds stay as text.
 *
 * On the render core. Tokens are every image embed (resolved or not, so a
 * refreshed attachment list re-decorates without a rescan) and every fenced
 * block, which is what makes a line outside a fence neutral.
 */
function embedRenderer(opts: AttachmentEmbedOpts): TextRenderer<EmbedToken> {
	return {
		kind: "text",
		reveal: true,
		usesTree: true,
		refresh: (tr) =>
			tr.startState.facet(translator) !== tr.state.facet(translator) ||
			tr.effects.some((e) => e.is(refreshAttachmentEmbeds)),
		keep: (state, t, from, to) => t.value === null && fenceSurvives(state.doc, t, from, to),
		scan(state, from, emit, neutral) {
			scanFenced(
				state,
				from,
				neutral,
				(fence) => emit({ from: fence.from, to: fence.to, value: null }),
				(line) => {
					for (const m of line.text.matchAll(EMBED)) {
						const target = (m.groups?.target ?? "").trim();
						if (IMAGE.test(target)) {
							const at = line.from + (m.index ?? 0);
							emit({
								from: at,
								to: at + m[0].length,
								value: { target, alias: (m.groups?.alias ?? "").trim() },
							});
						}
					}
				},
			);
		},
		decorate(state, t) {
			const embed = t.value;
			if (embed === null) {
				return [];
			}
			const path = opts.resolve(embed.target);
			if (path === null || inCode(syntaxTree(state), t.from)) {
				return [];
			}
			const width = /^\d+$/u.test(embed.alias) ? Number(embed.alias) : null;
			return [
				Decoration.replace({
					widget: new EmbedWidget(
						path,
						width === null ? embed.alias || embed.target : embed.target,
						width,
						opts.load,
						state.facet(translator),
					),
				}).range(t.from, t.to),
			];
		},
	};
}

/** Dispatch when the attachments list changed, so embeds resolve again without rebuilding the editor. */
export const refreshAttachmentEmbeds = StateEffect.define<null>();

export function attachmentEmbeds(opts: AttachmentEmbedOpts) {
	return [
		defineRenderer(embedRenderer(opts)),
		EditorView.baseTheme({
			".cm-attachment-embed": {
				display: "inline-block",
				maxWidth: "100%",
				verticalAlign: "bottom",
			},
			".cm-attachment-embed img": { maxWidth: "100%", borderRadius: "4px", display: "block" },
			".cm-attachment-embed-error": { color: "var(--destructive, red)", fontSize: "0.85em" },
		}),
	];
}

/** Is `target` an image the embed layer will draw? Atomic's wikilink widget must skip these. */
export function isImageEmbedTarget(opts: AttachmentEmbedOpts, target: string): boolean {
	return IMAGE.test(target.trim()) && opts.resolve(target.trim()) !== null;
}

export { embedRenderer };
