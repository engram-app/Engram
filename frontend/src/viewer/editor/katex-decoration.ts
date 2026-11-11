import { Decoration, WidgetType } from "@codemirror/view";
import katex from "katex";
import { INLINE_MATH } from "../../lib/math-delimiters";
import { defineRenderer, searchForward, type TextRenderer } from "./render-core";
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

interface MathSpan {
	tex: string;
	/** Written as `$$…$$`. */
	display: boolean;
}

// `$…$` per pandoc's rules (lib/math-delimiters.ts), tried at one position.
const INLINE_AT = new RegExp(INLINE_MATH.source, "y");

/**
 * Math spans, matched exactly as the regex `\$\$[^$]+\$\$|<inline>` would over the
 * whole note, but walking lines from a neutral point. A `$$` opens a display
 * span that ends at the next `$` if a second `$` follows it, wherever that is
 * (it may be lines down); otherwise it is tried as inline math. Inline math
 * never crosses a line. A line start outside a span is neutral.
 */
export const katexRenderer: TextRenderer<MathSpan | null> = {
	kind: "text",
	reveal: true,
	// An unpaired `$$` holds until a `$` is typed inside it.
	keep: (state, t, from, to) => t.value === null && !state.sliceDoc(from, to).includes("$"),
	scan(state, from, emit, neutral) {
		const { doc } = state;
		let pos = from;
		while (pos <= doc.length) {
			const line = doc.lineAt(pos);
			if (pos === line.from && pos > from && neutral(pos)) {
				return;
			}
			const { text } = line;
			let i = pos - line.from;
			let next = line.to + 1; // where to continue: the next line, unless a span crosses lines
			while (i < text.length) {
				const j = text.indexOf("$", i);
				if (j < 0) {
					break;
				}
				const s = line.from + j;
				if (text[j + 1] === "$") {
					const q = searchForward(doc, s + 2, "$");
					const paired = q > s + 2 && doc.sliceString(q + 1, q + 2) === "$";
					if (!paired && q !== s + 2) {
						// Unpaired `$$`: no span yet, but typing a `$$` anywhere up to the
						// next `$` would close it. An unrendered token over that stretch
						// makes the core rescan from here when it happens, the way an
						// unclosed fence or comment does.
						emit({ from: s, to: q < 0 ? doc.length : q + 1, value: null });
					}
					if (paired) {
						emit({
							from: s,
							to: q + 2,
							value: { tex: doc.sliceString(s + 2, q).trim(), display: true },
						});
						if (q + 2 > line.to) {
							next = q + 2;
							break;
						}
						i = q + 2 - line.from;
						continue;
					}
				}
				INLINE_AT.lastIndex = j;
				const m = INLINE_AT.exec(text);
				if (m) {
					emit({
						from: s,
						to: s + m[0].length,
						value: { tex: (m.groups?.inline ?? "").trim(), display: false },
					});
					i = j + m[0].length;
					continue;
				}
				i = j + 1;
			}
			pos = next;
		}
	},
	decorate(state, t) {
		if (t.value === null) {
			return [];
		}
		const { doc } = state;
		// A `$$…$$` span is display math ONLY when it occupies whole lines (its own
		// paragraph). Then it becomes a block widget, the one decoration shape that
		// MUST live in a StateField, never a ViewPlugin (CM6 rejects line-break-
		// spanning / block decorations from plugins). Mid-line `$$x$$` stays an
		// inline replace so we never emit an invalid block decoration.
		const wholeLine =
			t.value.display && doc.lineAt(t.from).from === t.from && doc.lineAt(t.to).to === t.to;
		const spec = wholeLine
			? { widget: new MathWidget(t.value.tex, true), block: true }
			: { widget: new MathWidget(t.value.tex, false) };
		return [Decoration.replace(spec).range(t.from, t.to)];
	},
};

// On the render core: a StateField underneath, because block math replaces line
// breaks. A keystroke rescans from the line before it to where the scan agrees
// with the old one again; a caret move re-decorates only the spans it touches.
export const katexDecoration = defineRenderer(katexRenderer);
