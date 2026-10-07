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

interface CommentRange {
	from: number;
	to: number;
	kind: "percent" | "html";
}

const FENCE = /^ {0,3}(?<marker>`{3,}|~{3,})/u;

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
	let fence: string | null = null;
	let i = 0;
	while (i < n) {
		const lineEnd = text.indexOf("\n", i);
		const end = lineEnd < 0 ? n : lineEnd;
		const atLineStart = i === 0 || text[i - 1] === "\n";
		if (atLineStart) {
			const f = FENCE.exec(text.slice(i, end));
			const marker = f?.groups?.marker;
			if (fence !== null) {
				// A closing fence uses the same character, at least as long.
				if (marker && marker[0] === fence[0] && marker.length >= fence.length) {
					fence = null;
				}
				i = end + 1;
				continue;
			}
			if (marker) {
				fence = marker;
				i = end + 1;
				continue;
			}
		} else if (fence !== null) {
			i = end + 1;
			continue;
		}
		let j = i;
		let jumped = false;
		while (j < end) {
			const ch = text[j];
			if (ch === "`") {
				let k = j;
				while (text[k] === "`") {
					k++;
				}
				const close = inlineCodeEnd(text, j, k - j, end);
				j = close >= 0 ? close : k;
				continue;
			}
			if (ch === "%" && text[j + 1] === "%") {
				const close = text.indexOf("%%", j + 2);
				const to = close < 0 ? n : close + 2;
				out.push({ from: j, to, kind: "percent" });
				i = to;
				jumped = true;
				break;
			}
			if (ch === "<" && text.startsWith("<!--", j)) {
				const close = text.indexOf("-->", j + 4);
				const to = close < 0 ? n : close + 3;
				out.push({ from: j, to, kind: "html" });
				i = to;
				jumped = true;
				break;
			}
			j++;
		}
		if (!jumped) {
			i = end + 1;
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
