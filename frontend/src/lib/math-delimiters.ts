// Which `$` characters are math delimiters.
//
// `$…$` is inline math only by pandoc's rules: the opening `$` is followed by a
// non-space, the closing `$` is preceded by a non-space and NOT followed by a
// digit, and `\$` is a literal dollar. Those rules are what keep prices from
// reading as math. Without them, `**$175k base** … **$150k base**` parsed as one
// math span that swallowed the bold markers between the two dollar amounts.
//
// Shared by the editor's math widget (viewer/editor/katex-decoration.ts) and the
// reading view (viewer/note-view.tsx), so both agree on what is math.

import { scanLines } from "./md-lines";

/** An inline `$…$` span. The TeX is in the `inline` group. */
const INLINE_MATH = /(?<!\\)\$(?<inline>[^\s$](?:[^$\n]*[^\s$\\])?)\$(?!\d)/g;

// A `$`: a whole `$$…$$` span, a valid inline span, or a lone `$` (the case to escape).
const DOLLAR = new RegExp(String.raw`\$\$[^$]*\$\$|${INLINE_MATH.source}|\$`, "g");
// Left alone: a code span, or an autolink (a backslash would change its URL).
const SKIP = /(?<skip>`+[^`]*`+|<[a-z][a-z0-9+.-]*:[^\s<>]*>)/iu;

/** Escape the lone `$` in a stretch of text that contains no code spans. */
function escapeText(text: string): string {
	let out = "";
	let at = 0;
	for (const m of text.matchAll(DOLLAR)) {
		const index = m.index ?? 0;
		out += text.slice(at, index);
		out += m[0] === "$" && text[index - 1] !== "\\" ? "\\$" : m[0];
		at = index + m[0].length;
	}
	return out + text.slice(at);
}

function escapeLine(line: string): string {
	// Odd parts of the split are the SKIP matches.
	return line
		.split(SKIP)
		.map((part, i) => (i % 2 === 1 ? part : escapeText(part)))
		.join("");
}

/**
 * Escape every `$` that is not a math delimiter (`\$`), so a renderer that does
 * not apply the rules above (remark-math) shows prices as text. Fenced code,
 * inline code, `$$` blocks and already-escaped dollars are left untouched.
 */
function escapeNonMathDollars(markdown: string): string {
	if (!markdown.includes("$")) {
		return markdown;
	}
	let inDisplay = false;
	const lines = scanLines(markdown);
	return lines
		.map((l) => {
			const raw = markdown.slice(l.start, l.end);
			if (l.code) {
				return raw;
			}
			const prefix = raw.slice(0, l.body - l.start);
			const line = raw.slice(prefix.length);
			const trimmed = line.trim();
			if (inDisplay) {
				inDisplay = !trimmed.endsWith("$$");
				return raw;
			}
			if (trimmed.startsWith("$$")) {
				// `$$x$$` on one line is closed; a bare `$$` (or `$$ …`) opens a block.
				inDisplay = !(trimmed.length > 3 && trimmed.endsWith("$$"));
				return raw;
			}
			return prefix + escapeLine(line);
		})
		.join("\n");
}

export { escapeNonMathDollars, INLINE_MATH };
