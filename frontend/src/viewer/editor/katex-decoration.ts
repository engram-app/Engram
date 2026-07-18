import { type Range, RangeSetBuilder } from "@codemirror/state";
import {
	Decoration,
	type DecorationSet,
	type EditorView,
	ViewPlugin,
	type ViewUpdate,
	WidgetType,
} from "@codemirror/view";
import katex from "katex";
import "katex/dist/katex.min.css";

class MathWidget extends WidgetType {
	constructor(
		private readonly tex: string,
		private readonly block: boolean,
	) {
		super();
	}
	eq(other: MathWidget) {
		return other.tex === this.tex && other.block === this.block;
	}
	toDOM() {
		const span = document.createElement("span");
		span.className = "cm-katex-widget";
		try {
			span.innerHTML = katex.renderToString(this.tex, {
				displayMode: this.block,
				throwOnError: false,
			});
		} catch {
			span.textContent = this.block ? `$$${this.tex}$$` : `$${this.tex}$`;
		}
		return span;
	}
	ignoreEvent() {
		return false;
	}
}

// Match $$...$$ (block) or $...$ (inline, no newline). Minimal, deliberately not
// a full TeX tokenizer — matches Obsidian's pragmatic $ delimiters.
const MATH_RE = /\$\$(?<block>[^$]+)\$\$|\$(?<inline>[^$\n]+)\$/g;

function buildMath(view: EditorView): DecorationSet {
	const ranges: Range<Decoration>[] = [];
	const { selection: sel } = view.state;
	// ponytail: whole-doc scan; fine for typical note sizes. view.visibleRanges
	// is empty under happy-dom (no layout in tests) and unreliable pre-first-measure
	// in general, so we mirror Atomic's own ensureSyntaxTree whole-doc walk instead
	// of CM6's usual viewport-only decoration pattern.
	const text = view.state.sliceDoc(0);
	for (const m of text.matchAll(MATH_RE)) {
		const start = m.index ?? 0;
		const end = start + m[0].length;
		// Reveal raw when the cursor/selection intersects the span.
		const active = sel.ranges.some((r) => r.from <= end && r.to >= start);
		if (active) {
			continue;
		}
		const { block: blockTex, inline: inlineTex } = m.groups ?? {};
		const block = blockTex !== undefined;
		const tex = (blockTex ?? inlineTex ?? "").trim();
		ranges.push(Decoration.replace({ widget: new MathWidget(tex, block) }).range(start, end));
	}
	const builder = new RangeSetBuilder<Decoration>();
	for (const r of ranges.sort((a, b) => a.from - b.from)) {
		builder.add(r.from, r.to, r.value);
	}
	return builder.finish();
}

export const katexDecoration = ViewPlugin.fromClass(
	class {
		decorations: DecorationSet;
		constructor(view: EditorView) {
			this.decorations = buildMath(view);
		}
		update(u: ViewUpdate) {
			if (u.docChanged || u.selectionSet || u.viewportChanged) {
				this.decorations = buildMath(u.view);
			}
		}
	},
	{ decorations: (v) => v.decorations },
);
