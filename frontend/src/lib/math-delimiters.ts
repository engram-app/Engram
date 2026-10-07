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

/** An inline `$…$` span. The TeX is in the `inline` group. */
const INLINE_MATH = /(?<!\\)\$(?<inline>[^\s$](?:[^$\n]*[^\s$\\])?)\$(?!\d)/g;

const FENCE = /^\s*(?:```|~~~)/u;
// A `$`: a whole `$$…$$` span, a valid inline span, or a lone `$` (the case to escape).
const DOLLAR = new RegExp(String.raw`\$\$[^$]*\$\$|${INLINE_MATH.source}|\$`, "g");
const CODE_SPAN = /(`+[^`]*`+)/u;

function escapeLine(line: string): string {
	return line
		.split(CODE_SPAN)
		.map((part, i) =>
			// Odd parts are code spans, left alone.
			i % 2 === 1
				? part
				: part.replace(DOLLAR, (...args: unknown[]) => {
						// replace() args: match, <capture groups>, offset, string, <named groups>.
						const [m] = args as [string];
						const offset = args.at(-3) as number;
						return m === "$" && part[offset - 1] !== "\\" ? "\\$" : m;
					}),
		)
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
	let inFence = false;
	let inDisplay = false;
	return markdown
		.split("\n")
		.map((line) => {
			if (FENCE.test(line)) {
				inFence = !inFence;
				return line;
			}
			if (inFence) {
				return line;
			}
			const trimmed = line.trim();
			if (inDisplay) {
				inDisplay = !trimmed.endsWith("$$");
				return line;
			}
			if (trimmed.startsWith("$$")) {
				// `$$x$$` on one line is closed; a bare `$$` (or `$$ …`) opens a block.
				inDisplay = !(trimmed.length > 3 && trimmed.endsWith("$$"));
				return line;
			}
			return escapeLine(line);
		})
		.join("\n");
}

export { escapeNonMathDollars, INLINE_MATH };
