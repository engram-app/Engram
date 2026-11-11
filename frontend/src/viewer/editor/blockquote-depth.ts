import { Decoration } from "@codemirror/view";
import { defineRenderer, type TextRenderer } from "./render-core";

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

// Atomic renders every blockquote line with one flat rail (no nesting). We set
// a `--bq-depth` custom property per quote line; blockquote-depth.css reads it
// to indent and draw one rail per nesting level. View-only: only line
// attributes, never a document change, so safe over the yCollab Y.Text binding.
// One token per quote line; a line carries no state, so every line is neutral.
export const blockquoteRenderer: TextRenderer<number> = {
	kind: "text",
	scan(state, from, emit, neutral) {
		const { doc } = state;
		for (let n = doc.lineAt(from).number; n <= doc.lines; n++) {
			const line = doc.line(n);
			if (line.from > from && neutral(line.from)) {
				return;
			}
			const depth = blockquoteDepth(line.text);
			if (depth > 0) {
				emit({ from: line.from, to: line.to, value: depth });
			}
		}
	},
	decorate: (_state, t) => [
		Decoration.line({ attributes: { style: `--bq-depth:${t.value}` } }).range(t.from),
	],
};

export const blockquoteDepthPlugin = defineRenderer(blockquoteRenderer);
