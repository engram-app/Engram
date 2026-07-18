import { type EditorState, type Range, RangeSetBuilder, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView, WidgetType } from "@codemirror/view";
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
		const el = document.createElement(this.block ? "div" : "span");
		el.className = "cm-katex-widget";
		try {
			el.innerHTML = katex.renderToString(this.tex, {
				displayMode: this.block,
				throwOnError: false,
			});
		} catch {
			el.textContent = this.block ? `$$${this.tex}$$` : `$${this.tex}$`;
		}
		return el;
	}
	ignoreEvent() {
		return false;
	}
}

// Match $$...$$ (block) or $...$ (inline, no newline). Minimal, deliberately not
// a full TeX tokenizer — matches Obsidian's pragmatic $ delimiters.
const MATH_RE = /\$\$(?<block>[^$]+)\$\$|\$(?<inline>[^$\n]+)\$/g;

function buildMath(state: EditorState): DecorationSet {
	const ranges: Range<Decoration>[] = [];
	const sel = state.selection;
	const text = state.sliceDoc(0);
	for (const m of text.matchAll(MATH_RE)) {
		const start = m.index ?? 0;
		const end = start + m[0].length;
		// Reveal raw when the cursor/selection intersects the span.
		const active = sel.ranges.some((r) => r.from <= end && r.to >= start);
		if (active) {
			continue;
		}
		const { block: blockTex, inline: inlineTex } = m.groups ?? {};
		const tex = (blockTex ?? inlineTex ?? "").trim();
		// A `$$…$$` match is display math ONLY when it occupies whole lines (its own
		// paragraph). Then it becomes a block widget — the one decoration shape that
		// MUST live in a StateField, never a ViewPlugin (CM6 rejects line-break-
		// spanning / block decorations from plugins). Mid-line `$$x$$` stays an
		// inline replace so we never emit an invalid block decoration.
		const wholeLine =
			blockTex !== undefined &&
			state.doc.lineAt(start).from === start &&
			state.doc.lineAt(end).to === end;
		const spec = wholeLine
			? { widget: new MathWidget(tex, true), block: true }
			: { widget: new MathWidget(tex, false) };
		ranges.push(Decoration.replace(spec).range(start, end));
	}
	const builder = new RangeSetBuilder<Decoration>();
	for (const r of ranges.sort((a, b) => a.from - b.from)) {
		builder.add(r.from, r.to, r.value);
	}
	return builder.finish();
}

// StateField (not ViewPlugin): block math replaces line breaks, which CM6 only
// permits from the decorations facet fed by a state field. Rebuild on any doc or
// selection change so the reveal-on-cursor behaviour still works.
export const katexDecoration = StateField.define<DecorationSet>({
	create: (state) => buildMath(state),
	update(value, tr) {
		if (tr.docChanged || tr.selection) {
			return buildMath(tr.state);
		}
		return value;
	},
	provide: (f) => EditorView.decorations.from(f),
});
