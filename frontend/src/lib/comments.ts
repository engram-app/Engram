// Markdown comments. Neither form is a markdown standard:
//   `%%…%%`      Obsidian's comment, inline or a multi-line block. Obsidian shows
//                it (greyed) while editing and hides it when reading. An unclosed
//                `%%` hides the rest of the note, as in Obsidian.
//   `<!-- … -->` plain HTML. CommonMark and GFM pass it through and every
//                renderer hides it, so it is the one form that is hidden everywhere.
// Both are ignored inside fenced code and inline code.
//
// Shared by the editor (viewer/editor/comment-decoration.ts greys them) and the
// reading view (viewer/note-view.tsx strips them).

import { scanLines } from "./md-lines";

interface CommentRange {
	from: number;
	to: number;
	kind: "percent" | "html";
}

/** End index (exclusive) of the inline-code span opened by `run` backticks at `from`, or -1. */
function inlineCodeEnd(text: string, from: number, run: number, limit: number): number {
	const closer = "`".repeat(run);
	let k = from + run;
	while (k < limit) {
		const at = text.indexOf(closer, k);
		if (at < 0 || at >= limit) {
			return -1;
		}
		// Must be an exact run: not part of a longer one.
		if (text[at + run] !== "`" && text[at - 1] !== "`") {
			return at + run;
		}
		k = at + 1;
	}
	return -1;
}

/** Every comment in `text`, in order, outside code. */
function findComments(text: string): CommentRange[] {
	const out: CommentRange[] = [];
	const n = text.length;
	let resume = 0; // a multi-line comment swallows the lines it spans
	for (const line of scanLines(text)) {
		if (line.code || line.end <= resume) {
			continue;
		}
		let j = Math.max(line.body, resume);
		while (j < line.end) {
			const ch = text[j];
			if (ch === "`") {
				let k = j;
				while (text[k] === "`") {
					k++;
				}
				const close = inlineCodeEnd(text, j, k - j, line.end);
				j = close >= 0 ? close : k;
				continue;
			}
			const percent = ch === "%" && text[j + 1] === "%";
			if (percent || (ch === "<" && text.startsWith("<!--", j))) {
				const closer = percent ? "%%" : "-->";
				const close = text.indexOf(closer, j + (percent ? 2 : 4));
				const to = close < 0 ? n : close + closer.length;
				out.push({ from: j, to, kind: percent ? "percent" : "html" });
				resume = to;
				j = to;
				continue;
			}
			j++;
		}
	}
	return out;
}

/** `text` with every comment removed (code is left alone). */
function stripComments(text: string): string {
	const comments = findComments(text);
	if (comments.length === 0) {
		return text;
	}
	let out = "";
	let at = 0;
	for (const c of comments) {
		out += text.slice(at, c.from);
		at = c.to;
	}
	return out + text.slice(at);
}

export type { CommentRange };
export { findComments, stripComments };
