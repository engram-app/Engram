import type { Range } from "@codemirror/state";
import { Decoration } from "@codemirror/view";
import { defineRenderer, type TreeRenderer } from "./render-core";

// A paragraph indented by a tab (or 4 spaces) with no list above it is a Markdown
// code block. Atomic gives fenced code its monospace + tinted background + left
// rail, but leaves an indented block as bare monospace text, so one stray Tab
// silently turns prose into code with nothing to say so (and `[text](url)` stops
// rendering as a link). Give it the fenced-code look: same class, same CSS.
// View-only: line classes, never a document change.
const INDENT_ONLY = /^(?:\t| {4})[ \t]*$/u;

const LINE = Decoration.line({ class: "cm-atomic-fenced-code cm-indented-code" });

/** Code-block line classes for the lines in [from, to); the core walks only that region. */
export const indentedCodeRenderer: TreeRenderer = {
	kind: "tree",
	visit(state, from, to) {
		const { doc } = state;
		const out: Range<Decoration>[] = [];
		const stop = to >= doc.length ? doc.length + 1 : to;
		return {
			enter(node) {
				if (node.name !== "CodeBlock") {
					return;
				}
				let last = doc.lineAt(node.to).number;
				// The parser ends a block at its last line with text, but Enter on an indented
				// line leaves a whitespace-only `\t` line that is where you are still typing.
				// Keep the styling running through those, or it drops out on every new line.
				while (last < doc.lines && INDENT_ONLY.test(doc.line(last + 1).text)) {
					last++;
				}
				for (let n = doc.lineAt(Math.max(node.from, from)).number; n <= last; n++) {
					const at = doc.line(n).from;
					if (at >= stop) {
						break;
					}
					if (at >= from) {
						out.push(LINE.range(at));
					}
				}
			},
			finish: () => out,
		};
	},
};

export const indentedCodeLines = defineRenderer(indentedCodeRenderer);
