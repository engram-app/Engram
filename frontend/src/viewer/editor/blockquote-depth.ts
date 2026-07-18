import { type Range, RangeSetBuilder } from "@codemirror/state";
import {
	Decoration,
	type DecorationSet,
	type EditorView,
	ViewPlugin,
	type ViewUpdate,
} from "@codemirror/view";

// Atomic renders every blockquote line with one flat rail (no nesting). We set
// a `--bq-depth` custom property per quote line; blockquote-depth.css reads it
// to indent and draw one rail per nesting level. View-only: only line
// attributes, never a document change — safe over the yCollab Y.Text binding.
function buildBlockquoteDecorations(view: EditorView): DecorationSet {
	const ranges: Range<Decoration>[] = [];
	// ponytail: whole-doc scan (matches Atomic's own approach; fine for typical
	// note sizes). Line decorations must be added at line-start in ascending order.
	const { doc } = view.state;
	for (let n = 1; n <= doc.lines; n++) {
		const line = doc.line(n);
		const depth = blockquoteDepth(line.text);
		if (depth > 0) {
			ranges.push(
				Decoration.line({ attributes: { style: `--bq-depth:${depth}` } }).range(line.from),
			);
		}
	}
	const builder = new RangeSetBuilder<Decoration>();
	for (const r of ranges) {
		builder.add(r.from, r.to, r.value);
	}
	return builder.finish();
}

/**
 * Count a line's blockquote nesting depth from its leading `>` markers.
 * `> a` -> 1, `>> b` / `> > c` -> 2, `>>> d` -> 3, plain text -> 0.
 * A `>` that isn't at the start of the line (e.g. `a > b`) is not a quote.
 */
export function blockquoteDepth(lineText: string): number {
	const prefix = lineText.match(/^(?:\s*>)+/);
	if (!prefix) {
		return 0;
	}
	return (prefix[0].match(/>/g) ?? []).length;
}

export const blockquoteDepthPlugin = ViewPlugin.fromClass(
	class {
		decorations: DecorationSet;
		constructor(view: EditorView) {
			this.decorations = buildBlockquoteDecorations(view);
		}
		update(u: ViewUpdate) {
			// Whole-doc scan → whole-doc line decorations: no viewport dependency,
			// so only a doc change can alter the output. (Offscreen line decos are
			// already in the RangeSet and render as lines scroll into view.)
			if (u.docChanged) {
				this.decorations = buildBlockquoteDecorations(u.view);
			}
		}
	},
	{ decorations: (v) => v.decorations },
);
