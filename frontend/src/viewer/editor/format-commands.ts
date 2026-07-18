import { indentWithTab } from "@codemirror/commands";
import { type ChangeSpec, EditorSelection, type Extension } from "@codemirror/state";
import { type EditorView, keymap } from "@codemirror/view";

/** Tab indents / Shift-Tab dedents the selected lines (Obsidian parity). */
export const indentKeymap: Extension = keymap.of([indentWithTab]);

/** Wrap each selection range with `before`/`after` markers (e.g. ** for bold). */
export function toggleWrap(view: EditorView, before: string, after: string = before): void {
	view.dispatch(
		view.state.changeByRange((range) => ({
			changes: [
				{ from: range.from, insert: before },
				{ from: range.to, insert: after },
			],
			range: EditorSelection.range(range.from + before.length, range.to + before.length),
		})),
	);
	view.focus();
}

/** Prepend `prefix` (e.g. "# ", "> ", "- ") to each line the selection touches. */
export function toggleLinePrefix(view: EditorView, prefix: string): void {
	const { state } = view;
	const changes: ChangeSpec[] = [];
	const seen = new Set<number>();
	for (const range of state.selection.ranges) {
		// Mirror CodeMirror's selectedLineBlocks: a non-empty selection ending exactly
		// at the start of a line does not select any character of that line.
		const endPos =
			!range.empty && state.doc.lineAt(range.to).from === range.to ? range.to - 1 : range.to;
		let pos = range.from;
		while (pos <= endPos) {
			const line = state.doc.lineAt(pos);
			if (!seen.has(line.number)) {
				seen.add(line.number);
				if (!line.text.startsWith(prefix)) {
					changes.push({ from: line.from, insert: prefix });
				}
			}
			pos = line.to + 1;
			if (line.to >= state.doc.length) {
				break;
			}
		}
	}
	if (changes.length > 0) {
		view.dispatch({ changes });
	}
	view.focus();
}
