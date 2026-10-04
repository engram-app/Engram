import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import { type EditorState, type Range, StateEffect, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
import type { SyntaxNode, Tree } from "@lezer/common";
import { selectionTouches } from "./decoration-utils";

interface AttachmentEmbedOpts {
	/** Embed target (`pic.png`, `img/pic.png`) to the attachment's vault path, or null. */
	resolve: (target: string) => string | null;
	/** Authenticated fetch of the attachment bytes, as an object URL. */
	load: (path: string) => Promise<string>;
}

const IMAGE = /\.(?:png|jpe?g|gif|webp|svg|avif|bmp)$/iu;
const EMBED = /!\[\[(?<target>[^\]|]+)(?:\|(?<alias>[^\]]*))?\]\]/gu;
const FENCE = /^ {0,3}(?:`{3,}|~{3,})/u;

class EmbedWidget extends WidgetType {
	constructor(
		private readonly path: string,
		private readonly alt: string,
		private readonly width: number | null,
		private readonly load: AttachmentEmbedOpts["load"],
	) {
		super();
	}

	eq(other: EmbedWidget) {
		return other.path === this.path && other.alt === this.alt && other.width === this.width;
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
				wrap.textContent = `Couldn't load ${this.path}`;
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

function build(state: EditorState, opts: AttachmentEmbedOpts): DecorationSet {
	const out: Range<Decoration>[] = [];
	// Parsed once per build, not once per embed.
	const tree = ensureSyntaxTree(state, state.doc.length, 100) ?? syntaxTree(state);
	let inFence = false;
	for (let n = 1; n <= state.doc.lines; n++) {
		const line = state.doc.line(n);
		if (FENCE.test(line.text)) {
			inFence = !inFence;
			continue;
		}
		if (inFence) {
			continue;
		}
		for (const m of line.text.matchAll(EMBED)) {
			const target = (m.groups?.target ?? "").trim();
			if (!IMAGE.test(target)) {
				continue;
			}
			const path = opts.resolve(target);
			if (path === null) {
				continue;
			}
			const from = line.from + (m.index ?? 0);
			const to = from + m[0].length;
			if (inCode(tree, from) || selectionTouches(state.selection, from, to)) {
				continue;
			}
			const alias = (m.groups?.alias ?? "").trim();
			const width = /^\d+$/u.test(alias) ? Number(alias) : null;
			out.push(
				Decoration.replace({
					widget: new EmbedWidget(
						path,
						width === null ? alias || target : target,
						width,
						opts.load,
					),
				}).range(from, to),
			);
		}
	}
	return Decoration.set(out);
}

/**
 * Obsidian-style image embeds: `![[pic.png]]` renders as the image, and the raw
 * source comes back while the caret is on it. View-only (never edits the doc).
 * Images only; other embeds stay as text.
 *
 * ponytail: rescans the whole doc on every change. Cheap at note sizes; narrow it
 * to the changed lines if a huge note makes typing lag.
 */
/** Dispatch when the attachments list changed, so embeds resolve again without rebuilding the editor. */
export const refreshAttachmentEmbeds = StateEffect.define<null>();

export function attachmentEmbeds(opts: AttachmentEmbedOpts) {
	return [
		StateField.define<DecorationSet>({
			create: (state) => build(state, opts),
			update: (deco, tr) =>
				tr.docChanged || tr.selection || tr.effects.some((e) => e.is(refreshAttachmentEmbeds))
					? build(tr.state, opts)
					: deco,
			provide: (f) => EditorView.decorations.from(f),
		}),
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
