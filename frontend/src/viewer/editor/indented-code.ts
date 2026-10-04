import { ensureSyntaxTree, syntaxTree } from "@codemirror/language";
import type { EditorState, Range } from "@codemirror/state";
import { StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";

// A paragraph indented by a tab (or 4 spaces) with no list above it is a Markdown
// code block. Atomic gives fenced code its monospace + tinted background + left
// rail, but leaves an indented block as bare monospace text, so one stray Tab
// silently turns prose into code with nothing to say so (and `[text](url)` stops
// rendering as a link). Give it the fenced-code look: same class, same CSS.
// View-only: line classes, never a document change.
const INDENT_ONLY = /^(?:\t| {4})[ \t]*$/u;

function build(state: EditorState): DecorationSet {
	const out: Range<Decoration>[] = [];
	// Bounded parse to the end of the doc: the tree is otherwise lazy and would
	// leave blocks below the viewport undecorated until they scroll in.
	// If the bounded parse times out, style what HAS parsed rather than nothing.
	const tree = ensureSyntaxTree(state, state.doc.length, 100) ?? syntaxTree(state);
	tree.iterate({
		enter: (node) => {
			if (node.name !== "CodeBlock") {
				return;
			}
			let last = state.doc.lineAt(node.to).number;
			// The parser ends a block at its last line with text, but Enter on an indented
			// line leaves a whitespace-only `\t` line that is where you are still typing.
			// Keep the styling running through those, or it drops out on every new line.
			while (last < state.doc.lines && INDENT_ONLY.test(state.doc.line(last + 1).text)) {
				last++;
			}
			for (let n = state.doc.lineAt(node.from).number; n <= last; n++) {
				out.push(
					Decoration.line({ class: "cm-atomic-fenced-code cm-indented-code" }).range(
						state.doc.line(n).from,
					),
				);
			}
		},
	});
	return Decoration.set(out, true);
}

export const indentedCodeLines = StateField.define<DecorationSet>({
	create: build,
	update: (deco, tr) => (tr.docChanged ? build(tr.state) : deco),
	provide: (f) => EditorView.decorations.from(f),
});
