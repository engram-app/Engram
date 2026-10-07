// Line-level markdown structure shared by comments.ts and math-delimiters.ts:
// which lines are code (fenced or indented) and where each line's content starts
// after any `>` blockquote / callout prefix. Both modules must skip code, and a
// hand-rolled fence regex in each drifted apart (no nesting, no callouts, no
// indented code, `~~~` closing a ``` fence).

interface MdLine {
	/** Offset of the line's first character. */
	start: number;
	/** Offset just past the line's last character (before the `\n`). */
	end: number;
	/** Offset where the content begins, after any `>` prefix. */
	body: number;
	/** The line is a fence marker, inside a fence, or in an indented code block. */
	code: boolean;
}

const QUOTE_PREFIX = /^(?: {0,3}>[ \t]?)+/u;
const FENCE = /^[ \t]*(?<marker>`{3,}|~{3,})(?<rest>.*)$/u;
const LIST_ITEM = /^[ \t]*(?:[-+*]|\d{1,9}[.)])[ \t]/u;
const INDENTED = /^(?: {4}|\t)/u;

function scanLines(text: string): MdLine[] {
	const lines: MdLine[] = [];
	let fence: string | null = null;
	let prevBlank = true;
	let prevCode = false;
	// The last unindented, non-blank line opened a list: indented lines after it are list content.
	let inList = false;
	let start = 0;
	while (start <= text.length) {
		const nl = text.indexOf("\n", start);
		const end = nl < 0 ? text.length : nl;
		const line = text.slice(start, end);
		const prefix = QUOTE_PREFIX.exec(line)?.[0].length ?? 0;
		const content = line.slice(prefix);
		const blank = content.trim() === "";
		let code = false;
		const f = FENCE.exec(content);
		const marker = f?.groups?.marker;
		if (fence !== null) {
			code = true;
			// A closing fence: same character, at least as long, nothing after it.
			if (
				marker &&
				marker[0] === fence[0] &&
				marker.length >= fence.length &&
				!f?.groups?.rest.trim()
			) {
				fence = null;
			}
		} else if (marker && !(marker[0] === "`" && f?.groups?.rest.includes("`"))) {
			code = true;
			fence = marker;
		} else if (!blank && INDENTED.test(content) && !inList && (prevBlank || prevCode)) {
			code = true;
		}
		if (!(blank || code || INDENTED.test(content))) {
			inList = LIST_ITEM.test(content);
		}
		lines.push({ start, end, body: start + prefix, code });
		prevBlank = blank;
		prevCode = code;
		if (nl < 0) {
			break;
		}
		start = nl + 1;
	}
	return lines;
}

export type { MdLine };
export { scanLines };
