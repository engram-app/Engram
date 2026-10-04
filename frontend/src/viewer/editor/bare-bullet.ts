import type { MarkdownConfig } from "@lezer/markdown";

const DASH = 45;
const PLUS = 43;
const STAR = 42;

/**
 * A bullet marker alone on its line (`-`, `*`, `+` with nothing after, not even
 * a space) is an empty list item to CommonMark, so the live preview swapped it
 * for a dot the moment the dash was typed, then back to a dash once the next
 * character made it ordinary text (`-words`). Obsidian draws the bullet only
 * once `- ` is typed.
 *
 * Consumes that one line as plain text, before the list parser can claim it.
 * Ordered markers are untouched (they stay visible text either way), and a dash
 * under a paragraph still reads as a setext heading underline because the open
 * paragraph claims it first.
 */
export const bareBulletAsText: MarkdownConfig = {
	parseBlock: [
		{
			name: "BareBulletAsText",
			before: "BulletList",
			parse(cx, line) {
				const isBullet = line.next === DASH || line.next === PLUS || line.next === STAR;
				if (!isBullet || line.pos !== line.text.length - 1) {
					return false;
				}
				cx.nextLine();
				return true;
			},
		},
	],
};
