import type { EditorState, Line, Text } from "@codemirror/state";
import type { Token } from "./render-core";

// The one fenced-code scanner for the line renderers (mermaid, image embeds).
// CommonMark fences, not just ``` at column 0: a run of three or more backticks
// or tildes, indented up to three spaces. A closer is the SAME character, at
// least as long as the opener, and nothing else on the line; that is what lets
// a ````markdown block quote a ```mermaid one, and why ```js cannot close ````.
// Backtick info strings cannot contain a backtick, which keeps an inline code
// span on its own line from opening a fence.
//
// ponytail: three spaces is the CommonMark document-level allowance, so a fence
// indented further by a NESTED list item is missed. Upgrade path is to track
// container indentation; not worth it until someone hits it.

const OPEN = /^(?<indent> {0,3})(?<marker>`{3,}|~{3,})(?<info>.*)$/u;
const CLOSE = /^ {0,3}(?<marker>`{3,}|~{3,})[ \t]*$/u;

interface Opener {
	indent: number;
	marker: string;
	info: string;
}

interface Fence extends Opener {
	from: number;
	/** End of the closing line, or the doc end while the fence is still open. */
	to: number;
	openLine: number;
	/** 0 while unclosed: everything below is inside it. */
	closeLine: number;
}

function opener(text: string): Opener | null {
	const m = OPEN.exec(text);
	const marker = m?.groups?.marker;
	if (!marker) {
		return null;
	}
	const info = (m.groups?.info ?? "").trim();
	if (marker[0] === "`" && info.includes("`")) {
		return null;
	}
	return { indent: m.groups?.indent?.length ?? 0, marker, info };
}

function closes(text: string, marker: string): boolean {
	const m = CLOSE.exec(text)?.groups?.marker;
	return m !== undefined && m[0] === marker[0] && m.length >= marker.length;
}

/**
 * Walk lines from `from` (a neutral line start). Each fence goes to `onFence`
 * whole, its content never to `onLine`; every other line goes to `onLine`. At
 * each later line start outside a fence, `neutral` may end the walk.
 */
function scanFenced(
	state: EditorState,
	from: number,
	neutral: (lineStart: number) => boolean,
	onFence: (fence: Fence) => void,
	onLine: (line: Line) => void = () => undefined,
): void {
	const { doc } = state;
	let n = doc.lineAt(from).number;
	while (n <= doc.lines) {
		const line = doc.line(n);
		if (line.from > from && neutral(line.from)) {
			return;
		}
		const open = opener(line.text);
		if (!open) {
			onLine(line);
			n++;
			continue;
		}
		let close = 0;
		for (let k = n + 1; k <= doc.lines; k++) {
			if (closes(doc.line(k).text, open.marker)) {
				close = k;
				break;
			}
		}
		onFence({
			...open,
			from: line.from,
			to: close ? doc.line(close).to : doc.length,
			openLine: n,
			closeLine: close,
		});
		if (!close) {
			return;
		}
		n = close + 1;
	}
}

/**
 * An edit of lines [from, to] strictly inside a fence token leaves the fence
 * as it was unless one of those lines now closes it. Lets the core keep a
 * 5000-line fence without rescanning it on every keystroke inside.
 */
function fenceSurvives(doc: Text, t: Token<unknown>, from: number, to: number): boolean {
	const open = opener(doc.lineAt(t.from).text);
	if (!open) {
		return false;
	}
	for (let n = doc.lineAt(from).number; n <= doc.lineAt(to).number; n++) {
		if (closes(doc.line(n).text, open.marker)) {
			return false;
		}
	}
	return true;
}

export type { Fence };
export { fenceSurvives, scanFenced };
