import { indentWithTab } from "@codemirror/commands";
import { syntaxTree } from "@codemirror/language";
import {
	type ChangeSpec,
	EditorSelection,
	type EditorState,
	type Extension,
	type Line,
} from "@codemirror/state";
import { type EditorView, keymap } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

/** Opens with a line of only `-` or `=` — what CommonMark reads as a setext heading underline. */
const SETEXT_UNDERLINE = /^[-=]+[ \t]*(?:\n|$)/;

/**
 * Splits a line into its leading whitespace and the rest. Indentation carries
 * list nesting, so every checkbox rewrite has to put it back verbatim —
 * rebuilding from column 0 would flatten a sub-task to top level.
 */
const LINE_PARTS = /^(?<indent>[ \t]*)(?<body>.*)$/u;
/** `- [ ] `, `* [x] `, `+ [X] ` — any bullet marker, either checked state. */
const TASK = /^(?<marker>[-*+] )\[(?<state>[ xX])\] ?(?<rest>.*)$/u;
/** A bare list item: `- foo`, with no checkbox yet. */
const BULLET = /^(?<marker>[-*+] )(?<rest>.*)$/u;
/**
 * An ATX heading marker, matched against a line's body (indent already split
 * off). The trailing ` +` is required by CommonMark and is what keeps `#tag`
 * from reading as an empty h1 — without it, tapping a heading level on a line
 * starting with a tag would eat the tag's hash.
 */
const HEADING = /^(?<hashes>#{1,6}) +/u;

/**
 * Every line the selection touches, deduped, in document order.
 *
 * Mirrors CodeMirror's selectedLineBlocks: a non-empty selection ending exactly
 * at the start of a line does not select any character of that line. That
 * boundary rule is easy to get subtly wrong, so the three line commands below
 * share this one implementation rather than each carrying a copy.
 */
function selectedLines(state: EditorState): Line[] {
	const lines: Line[] = [];
	const seen = new Set<number>();
	for (const range of state.selection.ranges) {
		const endPos =
			!range.empty && state.doc.lineAt(range.to).from === range.to ? range.to - 1 : range.to;
		let pos = range.from;
		while (pos <= endPos) {
			const line = state.doc.lineAt(pos);
			if (!seen.has(line.number)) {
				seen.add(line.number);
				lines.push(line);
			}
			pos = line.to + 1;
			if (line.to >= state.doc.length) {
				break;
			}
		}
	}
	return lines;
}

/**
 * Apply `changes` and map the selection with assoc = 1.
 *
 * CodeMirror maps a caret sitting exactly ON an insertion point to BEFORE the
 * inserted text by default. For a line marker that is always wrong: tapping
 * the list button on an empty line left the caret to the left of the "- ", so
 * the next keystroke landed in front of the bullet and you had to move the
 * cursor by hand before typing. assoc = 1 pushes it to the far side instead.
 */
function dispatchKeepingCaretAfterInsert(view: EditorView, changes: ChangeSpec[]): void {
	const changeSet = view.state.changes(changes);
	view.dispatch({ changes: changeSet, selection: view.state.selection.map(changeSet, 1) });
}

/** Marker -> the syntax node the markdown grammar produces for it. */
const EMPHASIS_NODES: Record<string, string> = {
	"*": "Emphasis",
	_: "Emphasis",
	"**": "StrongEmphasis",
	__: "StrongEmphasis",
	"~~": "Strikethrough",
};

/**
 * The span of the emphasis of `marker`'s kind enclosing `[from, to)`, or null.
 *
 * Asks the PARSER rather than comparing the neighbouring characters, because
 * `*` is a prefix of `**` and string matching gets this wrong in both
 * directions: it reads `**bold**` as italic (so italicising would silently
 * downgrade it to `*bold*` instead of nesting to `***bold***`), and a rule
 * patched to avoid that then refuses to un-bold `***text***`. The grammar
 * already distinguishes Emphasis from StrongEmphasis; nothing here has to.
 *
 * Falls back to wrapping in an editor with no markdown language loaded, since
 * the tree is empty there.
 */
function enclosingEmphasis(state: EditorState, from: number, to: number, marker: string) {
	const len = marker.length;
	// The degenerate empty pair that wrapping itself produces: `**|**` is not
	// emphasis to the parser — CommonMark needs content — so a second tap of the
	// same button has to recognise it by text or it doubles to `****|****`.
	if (
		from === to &&
		from >= len &&
		to + len <= state.doc.length &&
		state.doc.sliceString(from - len, from) === marker &&
		state.doc.sliceString(to, to + len) === marker
	) {
		return { from: from - len, to: to + len };
	}
	const name = EMPHASIS_NODES[marker];
	if (!name) {
		return null;
	}
	let node: SyntaxNode | null = syntaxTree(state).resolveInner(from, 1);
	for (; node; node = node.parent) {
		if (node.name === name && node.from + len <= from && to <= node.to - len) {
			return { from: node.from, to: node.to };
		}
	}
	return null;
}

/** Tab indents / Shift-Tab dedents the selected lines (Obsidian parity). */
export const indentKeymap: Extension = keymap.of([indentWithTab]);

/**
 * Wrap each selection range with `before`/`after` markers (e.g. `**` for bold),
 * or strip them when they are already there.
 *
 * The unwrap half matters because these are BUTTONS: a wrap-only command turns
 * a second tap of "bold" into `****text****` rather than undoing the first.
 */
export function toggleWrap(view: EditorView, before: string, after: string = before): void {
	view.dispatch(
		view.state.changeByRange((range) => {
			const wrapping =
				before === after ? enclosingEmphasis(view.state, range.from, range.to, before) : null;
			if (wrapping) {
				return {
					changes: [
						{ from: wrapping.from, to: wrapping.from + before.length },
						{ from: wrapping.to - after.length, to: wrapping.to },
					],
					range: EditorSelection.range(range.from - before.length, range.to - before.length),
				};
			}
			return {
				changes: [
					{ from: range.from, insert: before },
					{ from: range.to, insert: after },
				],
				range: EditorSelection.range(range.from + before.length, range.to + before.length),
			};
		}),
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

/**
 * Obsidian's "toggle checkbox status" on every line the selection touches:
 * plain text and bare bullets become an unchecked task, an existing task flips
 * state. Flips rather than removing, because unchecking is the common action
 * and losing the task entirely is not recoverable by tapping again.
 */
export function toggleCheckbox(view: EditorView): void {
	const changes: ChangeSpec[] = [];
	for (const line of selectedLines(view.state)) {
		if (line.text.trim() === "") {
			continue;
		}
		const { indent = "", body = "" } = LINE_PARTS.exec(line.text)?.groups ?? {};
		// Edit only the marker, never the whole line. Rewriting the line
		// wholesale maps the caret to the line start — tap the button mid-word
		// and you lose your place.
		const bodyStart = line.from + indent.length;
		const task = TASK.exec(body)?.groups;
		const bullet = BULLET.exec(body)?.groups;
		if (task) {
			// Flip the single character inside the brackets.
			const statePos = bodyStart + (task.marker?.length ?? 0) + 1;
			const checked = task.state?.toLowerCase() === "x";
			changes.push({ from: statePos, to: statePos + 1, insert: checked ? " " : "x" });
		} else if (bullet) {
			changes.push({ from: bodyStart + (bullet.marker?.length ?? 0), insert: "[ ] " });
		} else {
			changes.push({ from: bodyStart, insert: "- [ ] " });
		}
	}
	if (changes.length > 0) {
		dispatchKeepingCaretAfterInsert(view, changes);
	}
	view.focus();
}

/**
 * Set the caret line(s) to heading `level`, Obsidian's heading menu.
 *
 * SETS rather than prepends: tapping H3 on an H1 line has to replace the
 * marker, where toggleLinePrefix would have produced "### # title" (a `# title`
 * line does not start with `### `). Tapping the level a line already has
 * removes it, which is the way back to plain text without a seventh button.
 */
export function setHeading(view: EditorView, level: number): void {
	const changes: ChangeSpec[] = [];
	for (const line of selectedLines(view.state)) {
		const { indent = "", body = "" } = LINE_PARTS.exec(line.text)?.groups ?? {};
		const from = line.from + indent.length;
		const existing = HEADING.exec(body);
		const hashes = existing?.groups?.hashes ?? "";
		changes.push({
			from,
			// Replace the whole existing marker INCLUDING its trailing spaces, so
			// re-leveling never leaves a double gap before the text.
			to: from + (existing?.[0].length ?? 0),
			insert: hashes.length === level ? "" : `${"#".repeat(level)} `,
		});
	}
	dispatchKeepingCaretAfterInsert(view, changes);
	view.focus();
}

/** Prepend `prefix` (e.g. "# ", "> ", "- ") to each line the selection touches. */
export function toggleLinePrefix(view: EditorView, prefix: string): void {
	const changes: ChangeSpec[] = [];
	for (const line of selectedLines(view.state)) {
		if (!line.text.startsWith(prefix)) {
			changes.push({ from: line.from, insert: prefix });
		}
	}
	if (changes.length > 0) {
		dispatchKeepingCaretAfterInsert(view, changes);
	}
	view.focus();
}
