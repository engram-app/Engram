import { indentLess, indentMore } from "@codemirror/commands";
import { indentUnit, syntaxTree } from "@codemirror/language";
import {
	type ChangeSpec,
	EditorSelection,
	type EditorState,
	type Extension,
	type Line,
	Prec,
} from "@codemirror/state";
import { type EditorView, keymap } from "@codemirror/view";
import type { SyntaxNode } from "@lezer/common";

/** A line that is only indentation. */
const INDENT_ONLY = /^[ \t]+$/u;

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
/** The marker of either list kind: `- `, `* `, `+ `, or `12. `. */
const LIST_MARKER = /^(?<marker>[-*+] |\d+\. )/u;
const ORDERED_MARKER = /^\d+\. $/u;
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
 * The lines a line command should act on: everything the selection touches,
 * minus the blank ones — unless a blank line is all there is.
 *
 * A marker on a blank line is wrong in every direction: it renders as an empty
 * heading, and it ENDS a list in markdown, so numbering one would split the
 * list and consume an ordinal besides. Blank lines are also exactly what
 * separate the paragraphs a multi-line selection spans. A lone blank line is
 * the opposite case: someone starting a list or a heading before typing it.
 *
 * Shared because it drifted once already — setHeading kept marking blank lines
 * after toggleList learned not to.
 */
function targetLines(state: EditorState): Line[] {
	const lines = selectedLines(state);
	return lines.length === 1 ? lines : lines.filter((line) => line.text.trim() !== "");
}

/** A line's leading whitespace and the rest, which every marker rewrite needs. */
function splitIndent(line: Line): { indent: string; body: string } {
	const { indent = "", body = "" } = LINE_PARTS.exec(line.text)?.groups ?? {};
	return { indent, body };
}

/**
 * Apply `changes`, mapping the selection with assoc = 1, then refocus.
 *
 * CodeMirror maps a caret sitting exactly ON an insertion point to BEFORE the
 * inserted text by default. For a line marker that is always wrong: tapping
 * the list button on an empty line left the caret to the left of the "- ", so
 * the next keystroke landed in front of the bullet and you had to move the
 * cursor by hand before typing. assoc = 1 pushes it to the far side instead.
 *
 * Refocusing is part of the same step because a toolbar command that edits
 * without returning focus leaves the keyboard closing on a phone.
 */
function applyLineChanges(view: EditorView, changes: ChangeSpec[]): void {
	if (changes.length > 0) {
		const changeSet = view.state.changes(changes);
		view.dispatch({ changes: changeSet, selection: view.state.selection.map(changeSet, 1) });
	}
	view.focus();
}

/** Marker -> the syntax node the markdown grammar produces for it. */
const MARKER_NODES: Record<string, string> = {
	"*": "Emphasis",
	_: "Emphasis",
	"**": "StrongEmphasis",
	__: "StrongEmphasis",
	"~~": "Strikethrough",
	"`": "InlineCode",
};

/**
 * A blockquote marker, with the space CommonMark treats as optional. Indent is
 * captured separately so unquoting strips only the marker — the indentation
 * carries nesting, and removing it would be an outdent, not an unquote.
 */
const QUOTE = /^(?<indent>[ \t]*)(?<marker>> ?)/u;

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
function enclosingEmphasis(
	state: EditorState,
	from: number,
	to: number,
	before: string,
	after: string,
) {
	// The degenerate empty pair that wrapping itself produces: `**|**` is not
	// emphasis to the parser — CommonMark needs content — so a second tap of the
	// same button has to recognise it by text or it doubles to `****|****`.
	// Handled before the node lookup so it covers asymmetric markers too, where
	// there is no node to find: `[[|]]` would otherwise become `[[[[]]]]`.
	if (
		from === to &&
		from >= before.length &&
		to + after.length <= state.doc.length &&
		state.doc.sliceString(from - before.length, from) === before &&
		state.doc.sliceString(to, to + after.length) === after
	) {
		return { from: from - before.length, to: to + after.length };
	}
	const name = before === after ? MARKER_NODES[before] : undefined;
	if (!name) {
		return null;
	}
	const len = before.length;
	let node: SyntaxNode | null = syntaxTree(state).resolveInner(from, 1);
	for (; node; node = node.parent) {
		if (node.name === name && node.from + len <= from && to <= node.to - len) {
			return { from: node.from, to: node.to };
		}
	}
	return null;
}

/** A list item line: `\t- foo`, `  12. foo`, `1) foo`. */
const LIST_ITEM = /^(?<indent>[ \t]*)(?:[-*+]|(?<num>\d+)(?<delim>[.)]))(?<gap> +)/u;
/** Columns per tab stop (CodeMirror's default, and Obsidian's). */
const TAB_COLS = 4;

interface ListItem {
	/** Indent width in columns, tabs expanded: what "same level" means. */
	cols: number;
	/** Ordered number, or null for a bullet. */
	num: number | null;
	delim: string;
}

function indentCols(ws: string): number {
	let cols = 0;
	for (const ch of ws) {
		cols += ch === "\t" ? TAB_COLS - (cols % TAB_COLS) : 1;
	}
	return cols;
}

function listItem(text: string): ListItem | null {
	const m = LIST_ITEM.exec(text);
	if (!m?.groups) {
		return null;
	}
	const { indent = "", num, delim = "" } = m.groups;
	return { cols: indentCols(indent), num: num === undefined ? null : Number(num), delim };
}

/** The ordered marker's number on `text`, swapped for `n`. */
function withNumber(text: string, n: number): string {
	return text.replace(/^(?<indent>[ \t]*)\d+/u, `$<indent>${n}`);
}

/** Number of the nearest same-level item above `at` (0 if a parent or the list start comes first). */
function numberAbove(lines: string[], at: number, cols: number): number {
	for (let i = at - 1; i >= 0; i--) {
		const text = lines[i] ?? "";
		if (text.trim() === "") {
			continue;
		}
		const item = listItem(text);
		if (!item) {
			if (/^\S/u.test(text)) {
				return 0;
			}
			continue;
		}
		if (item.cols < cols) {
			return 0;
		}
		if (item.cols === cols) {
			return item.num ?? 0;
		}
	}
	return 0;
}

/** Re-number the ordered item at `at` to follow its same-level predecessor. */
function renumberAt(lines: string[], at: number): void {
	const item = listItem(lines[at] ?? "");
	if (item && item.num !== null) {
		lines[at] = withNumber(lines[at] ?? "", numberAbove(lines, at, item.cols) + 1);
	}
}

/** Re-number the ordered siblings at `cols` below `from`, until the list level ends. */
function renumberBelow(lines: string[], from: number, cols: number): void {
	for (let i = from + 1; i < lines.length; i++) {
		const text = lines[i] ?? "";
		if (text.trim() === "") {
			continue;
		}
		const item = listItem(text);
		if (!item) {
			if (/^\S/u.test(text)) {
				return;
			}
			continue;
		}
		if (item.cols < cols) {
			return;
		}
		if (item.cols === cols) {
			renumberAt(lines, i);
		}
	}
}

/**
 * Tab / Shift-Tab on list lines `first..last`, as Obsidian does it (verified
 * against Obsidian 1.12 defaults): one `\t` in or out per press, never refused.
 * An ordered number restarts at the new level, and the siblings it left or
 * joined are renumbered. Returns null unless EVERY line is a list item, so the
 * caller can fall back to a plain indent.
 */
function shiftListLines(
	lines: string[],
	first: number,
	last: number,
	dir: 1 | -1,
): string[] | null {
	const out = [...lines];
	const levels = new Set<number>();
	for (let i = first; i <= last; i++) {
		const item = listItem(out[i] ?? "");
		if (!item) {
			return null;
		}
		levels.add(item.cols);
	}
	for (let i = first; i <= last; i++) {
		const text = out[i] ?? "";
		out[i] = dir > 0 ? `\t${text}` : text.replace(/^(?:\t| {1,4})/u, "");
	}
	for (let i = first; i <= last; i++) {
		renumberAt(out, i);
		levels.add(listItem(out[i] ?? "")?.cols ?? 0);
	}
	for (const cols of levels) {
		renumberBelow(out, last, cols);
	}
	return out;
}

/** The smallest single replacement turning `before` into `after`, so the caret keeps its place. */
function lineDiff(line: Line, after: string): ChangeSpec | null {
	const before = line.text;
	let start = 0;
	while (start < before.length && start < after.length && before[start] === after[start]) {
		start++;
	}
	let end = 0;
	while (
		end < before.length - start &&
		end < after.length - start &&
		before.at(-1 - end) === after.at(-1 - end)
	) {
		end++;
	}
	if (before === after) {
		return null;
	}
	return {
		from: line.from + start,
		to: line.from + before.length - end,
		insert: after.slice(start, after.length - end),
	};
}

function shiftList(view: EditorView, dir: 1 | -1): boolean {
	const { state } = view;
	// One span from first to last line is wrong for separate cursors (it would shift the
	// lines between them too); leave those to the plain per-line indent.
	if (state.selection.ranges.length > 1) {
		return false;
	}
	const sel = selectedLines(state);
	const [head] = sel;
	const tail = sel.at(-1);
	if (!(head && tail)) {
		return false;
	}
	const lines = state.doc.toString().split("\n");
	const shifted = shiftListLines(lines, head.number - 1, tail.number - 1, dir);
	if (!shifted) {
		return false;
	}
	const changes: ChangeSpec[] = [];
	for (let i = 0; i < shifted.length; i++) {
		const change = lineDiff(state.doc.line(i + 1), shifted[i] ?? "");
		if (change) {
			changes.push(change);
		}
	}
	if (changes.length > 0) {
		view.dispatch({ changes });
	}
	return true;
}

export const indentListItem = (view: EditorView): boolean => shiftList(view, 1);
export const outdentListItem = (view: EditorView): boolean => shiftList(view, -1);

/** What Tab does: nest a list item, or indent any other line. Also the mobile Indent button. */
export const indentSelection = (view: EditorView): boolean =>
	indentListItem(view) || indentMore(view);

/** What Shift-Tab does: un-nest a list item, or outdent any other line. Also the mobile Outdent button. */
export const outdentSelection = (view: EditorView): boolean =>
	outdentListItem(view) || indentLess(view);

/**
 * Enter on a line that is only indentation un-indents it and stops, instead of
 * adding another indented line (Obsidian: Enter in tab mode continues the indent,
 * and a second Enter with nothing typed leaves it). List items are the markdown
 * keymap's job, so this declines inside one.
 */
export function exitIndentedLine(view: EditorView): boolean {
	const { state } = view;
	const sel = state.selection.main;
	if (!sel.empty) {
		return false;
	}
	const line = state.doc.lineAt(sel.head);
	if (sel.head !== line.to || !INDENT_ONLY.test(line.text)) {
		return false;
	}
	// Inside a fenced block an indent-only line is just code: Enter must add a line.
	for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(line.from, -1); n; n = n.parent) {
		if (n.name === "FencedCode") {
			return false;
		}
	}
	// The parser ends a list item at its last line with text, so an indent-only line
	// below one is outside the node. Ask about the nearest line above with text.
	let above = line.number - 1;
	while (above >= 1 && state.doc.line(above).text.trim() === "") {
		above--;
	}
	if (above >= 1) {
		const pos = state.doc.line(above).to;
		for (let n: SyntaxNode | null = syntaxTree(state).resolveInner(pos, -1); n; n = n.parent) {
			if (n.name === "ListItem") {
				return false;
			}
		}
	}
	view.dispatch({
		changes: { from: line.from, to: line.to, insert: "" },
		selection: { anchor: line.from },
		userEvent: "delete.dedent",
	});
	return true;
}

/**
 * Tab / Shift-Tab, Obsidian parity: list items shift by one tab (see
 * shiftListLines); every other line gets a plain tab indent. `indentUnit` is a
 * tab so the plain path matches.
 */
export const indentKeymap: Extension = [
	indentUnit.of("\t"),
	keymap.of([{ key: "Tab", run: indentSelection, shift: outdentSelection }]),
	// Above the markdown keymap's own Enter, which would otherwise add a line.
	Prec.highest(keymap.of([{ key: "Enter", run: exitIndentedLine }])),
];

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
			const wrapping = enclosingEmphasis(view.state, range.from, range.to, before, after);
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
		const { indent, body } = splitIndent(line);
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
	applyLineChanges(view, changes);
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
	for (const line of targetLines(view.state)) {
		const { indent, body } = splitIndent(line);
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
	applyLineChanges(view, changes);
}

/**
 * Inline `` `code` `` for a selection on one line, a fenced block for one that
 * spans several.
 *
 * The split is not a nicety: inline backticks cannot span lines in CommonMark
 * (`` `a\nb` `` is literal text, not code), so wrapping a multi-line selection
 * inline would produce something that does not render as code at all.
 */
export function toggleCode(view: EditorView): void {
	const { from, to } = view.state.selection.main;
	if (!view.state.sliceDoc(from, to).includes("\n")) {
		toggleWrap(view, "`");
		return;
	}
	// Whole lines, like every other block command here. A fence only opens a
	// code block when it STARTS a line, so fencing the raw selection turned
	// "text one" selected from column 5 into "text ```" — markdown that renders
	// as prose with stray backticks, not as code.
	const start = view.state.doc.lineAt(from).from;
	const end = view.state.doc.lineAt(to).to;
	const body = view.state.sliceDoc(start, end);
	view.dispatch({
		changes: { from: start, to: end, insert: `\`\`\`\n${body}\n\`\`\`` },
		// Select the fenced body so the next keystroke can replace it, and so the
		// caret is not stranded after the closing fence.
		selection: EditorSelection.range(start + 4, start + 4 + body.length),
	});
	view.focus();
}

/** Prefix the selected lines with `> `, or strip the marker when all of them have it. */
export function toggleQuote(view: EditorView): void {
	const lines = selectedLines(view.state);
	// A mixed selection is being quoted, not unquoted — same rule as toggleList.
	const removing = lines.length > 0 && lines.every((line) => QUOTE.test(line.text));
	const changes = lines.map((line) => {
		const { indent = "", marker = "" } = QUOTE.exec(line.text)?.groups ?? {};
		const at = line.from + indent.length;
		return removing ? { from: at, to: at + marker.length, insert: "" } : { from: at, insert: "> " };
	});
	applyLineChanges(view, changes);
}

/**
 * `[text](url)` around the selection, caret in whichever slot still needs
 * filling: the URL when there is link text already, the text when there is not.
 *
 * Unlike the wikilink button this does NOT open the note picker — that button
 * covers linking to notes, and a filtered list of note names is in the way when
 * what you are about to paste is an external URL.
 */
export function insertLink(view: EditorView): void {
	view.dispatch(
		view.state.changeByRange((range) => {
			const text = view.state.sliceDoc(range.from, range.to);
			const insert = `[${text}]()`;
			return {
				changes: { from: range.from, to: range.to, insert },
				range: EditorSelection.cursor(range.from + (text ? insert.length - 1 : 1)),
			};
		}),
	);
	view.focus();
}

/**
 * Turn the selected lines into a bullet or numbered list, or back into plain
 * text when they already are one.
 *
 * ONE command for both kinds because they have to compose. Prefixing a numbered
 * line with `- ` gives `- 1. foo`; each kind has to be able to REPLACE the
 * other's marker, which a prefix-only command cannot do. Numbering is
 * sequential rather than a repeated `1. ` — CommonMark renders either the same,
 * but the source is what you look at in live preview.
 */
export function toggleList(view: EditorView, ordered: boolean): void {
	const items = targetLines(view.state).map((line) => {
		const { indent, body } = splitIndent(line);
		return {
			at: line.from + indent.length,
			marker: LIST_MARKER.exec(body)?.groups?.marker ?? "",
		};
	});
	const isKind = (marker: string) =>
		ordered ? ORDERED_MARKER.test(marker) : BULLET.test(marker) && marker.trimEnd().length === 1;
	// Only a list that is ALREADY entirely this kind toggles off; a mixed
	// selection is being converted, not cleared.
	const removing = items.length > 0 && items.every((item) => isKind(item.marker));
	const changes = items.map((item, index) => ({
		from: item.at,
		to: item.at + item.marker.length,
		insert: removing ? "" : ordered ? `${index + 1}. ` : "- ",
	}));
	applyLineChanges(view, changes);
}

/** Prepend `prefix` (e.g. "# ", "> ", "- ") to each line the selection touches. */
export function toggleLinePrefix(view: EditorView, prefix: string): void {
	const changes: ChangeSpec[] = [];
	for (const line of selectedLines(view.state)) {
		if (!line.text.startsWith(prefix)) {
			changes.push({ from: line.from, insert: prefix });
		}
	}
	applyLineChanges(view, changes);
}
