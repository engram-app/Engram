import { RangeSetBuilder } from "@codemirror/state";
import {
	Decoration,
	type DecorationSet,
	type EditorView,
	ViewPlugin,
	type ViewUpdate,
} from "@codemirror/view";
import "./callout.css";

// First line of a callout block: `> [!type]` optionally followed by a title.
const CALLOUT_START_RE = /^>\s*\[!(?<type>\w+)\]/;
// Any blockquote continuation line.
const BLOCKQUOTE_LINE_RE = /^>/;

function buildCallouts(view: EditorView): DecorationSet {
	const { doc, selection: sel } = view.state;
	const builder = new RangeSetBuilder<Decoration>();
	// ponytail: whole-doc scan; fine for typical note sizes. Same tradeoff as
	// katex-decoration.ts — view.visibleRanges is empty under happy-dom.
	let lineNo = 1;
	while (lineNo <= doc.lines) {
		const line = doc.line(lineNo);
		const m = CALLOUT_START_RE.exec(line.text);
		if (!m) {
			lineNo++;
			continue;
		}
		const type = (m.groups?.type ?? "").toLowerCase();
		let endLineNo = lineNo;
		while (endLineNo + 1 <= doc.lines) {
			const nextText = doc.line(endLineNo + 1).text;
			// A new `> [!type]` header always starts a fresh block, even though
			// it also matches the blockquote continuation regex.
			if (!BLOCKQUOTE_LINE_RE.test(nextText) || CALLOUT_START_RE.test(nextText)) {
				break;
			}
			endLineNo++;
		}
		const blockFrom = line.from;
		const blockTo = doc.line(endLineNo).to;
		// Reveal raw when the cursor/selection intersects the block.
		const active = sel.ranges.some((r) => r.from <= blockTo && r.to >= blockFrom);
		if (!active) {
			const deco = Decoration.line({ attributes: { class: `cm-callout cm-callout-${type}` } });
			for (let n = lineNo; n <= endLineNo; n++) {
				builder.add(doc.line(n).from, doc.line(n).from, deco);
			}
		}
		lineNo = endLineNo + 1;
	}
	return builder.finish();
}

export const calloutDecoration = ViewPlugin.fromClass(
	class {
		decorations: DecorationSet;
		constructor(view: EditorView) {
			this.decorations = buildCallouts(view);
		}
		update(u: ViewUpdate) {
			if (u.docChanged || u.selectionSet || u.viewportChanged) {
				this.decorations = buildCallouts(u.view);
			}
		}
	},
	{ decorations: (v) => v.decorations },
);
