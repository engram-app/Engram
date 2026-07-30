import { indentWithTab } from "@codemirror/commands";
import { type ChangeSpec, EditorSelection, type Extension } from "@codemirror/state";
import { type EditorView, keymap } from "@codemirror/view";

/** Opens with a line of only `-` or `=` — what CommonMark reads as a setext heading underline. */
const SETEXT_UNDERLINE = /^[-=]+[ \t]*(?:\n|$)/;

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

/**
 * Drop `snippet` in at the caret, replacing any selection.
 *
 * `block: true` marks snippets that are only valid at the start of a line
 * (callouts, tables, fences, rules). Those get newlines synthesized around them
 * so clicking "Insert" mid-paragraph produces valid markdown instead of a
 * callout glued onto the end of a sentence. Inline snippets are inserted
 * verbatim and never gain line breaks.
 *
 * One newline is enough for almost every block snippet: tables, fences, lists,
 * quotes and headings all legally INTERRUPT a paragraph in CommonMark. The
 * exception is a snippet that opens with a run of `-` or `=`, which is a setext
 * UNDERLINE when it directly follows paragraph text — `Text\n---` is an `<h2>`,
 * not a divider. So the rule and frontmatter entries silently ate the line above
 * and produced no rule at all, in the same panel whose rule row teaches the
 * blank-line requirement. Those get a blank line above instead.
 *
 * ponytail: the caret lands after the snippet rather than selecting a
 * placeholder inside it (e.g. the "text" in `**text**`). Upgrade path if that
 * proves annoying: give entries an explicit placeholder offset and select it
 * here instead of collapsing.
 */
export function insertSnippet(
	view: EditorView,
	snippet: string,
	{ block = false }: { block?: boolean } = {},
): void {
	const { state } = view;
	const { from, to } = state.selection.main;
	// Two lines, not one: with a multi-line selection the trailing remainder
	// lives on the line holding `to`. Slicing it out of the line holding `from`
	// indexed past that line's end, `slice` returned "", and the tail got glued
	// onto the snippet — "hello\nworld" selected [2,8] became "he\n| a |rld".
	const startLine = state.doc.lineAt(from);
	const endLine = state.doc.lineAt(to);
	// Only the text OUTSIDE the replaced range matters — a selection that spans
	// the whole line leaves it blank, so no break is needed on that side.
	let before = block && startLine.text.slice(0, from - startLine.from).trim() !== "" ? "\n" : "";
	const after = block && endLine.text.slice(to - endLine.from).trim() !== "" ? "\n" : "";

	if (block && SETEXT_UNDERLINE.test(snippet)) {
		const prevLine = startLine.number > 1 ? state.doc.line(startLine.number - 1) : null;
		if (before !== "") {
			before = "\n\n";
		} else if (prevLine !== null && prevLine.text.trim() !== "") {
			// The snippet already starts its own line, but the line above still
			// holds text — the caret sitting on the blank separator between two
			// paragraphs is the common case, and consuming it re-joins them.
			before = "\n";
		}
	}
	const insert = `${before}${snippet}${after}`;

	view.dispatch({
		changes: { from, to, insert },
		selection: { anchor: from + before.length + snippet.length },
		scrollIntoView: true,
	});
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
