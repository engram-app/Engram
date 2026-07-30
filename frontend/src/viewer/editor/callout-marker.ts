import { tags } from "@lezer/highlight";
import type { MarkdownConfig } from "@lezer/markdown";

/**
 * Teach the markdown grammar that `[!type]` is a callout marker, not a link.
 *
 * CommonMark has no callouts, so lezer parses `[!important]` as a SHORTCUT
 * REFERENCE LINK — `[text]` with the definition presumed to live elsewhere. It
 * emits a `Link` node whether or not any definition exists, and Atomic's
 * inline-preview then does what it does to every link: paints it link-coloured,
 * appends the little link icon after the `]`, and REPLACES the `[` and `]`
 * themselves so the syntax gets out of your way.
 *
 * On a callout header that produced two bugs at once. A stray link icon sat
 * after `[!important]` pointing at nothing — and worse, putting the caret on the
 * header to edit it showed `> !important Title`, with the brackets you came to
 * edit hidden. Both only on the REVEALED header; once the caret leaves,
 * callout-decoration.ts replaces the whole line and the damage is invisible,
 * which is why it survived this long.
 *
 * Fixed at the parse, not with a counter-decoration, because there is no
 * counter-decoration to write: a replace decoration cannot be un-replaced by a
 * later extension, and CodeMirror gives you no way to filter another
 * extension's ranges. No `Link` node means nothing downstream has anything to
 * act on — the icon, the colour and the bracket-hiding all follow from it.
 *
 * Installed `before: "Link"` so it claims the `[` first.
 */
const MARKER = /^\[!\w+\][+-]?/;

// `[` — the only character worth waking this parser up for.
const OPEN_BRACKET = 91;

// Longest real type is "attention" (9). 32 bounds the scan without ruling out a
// type the library might add.
const MAX_MARKER = 32;

export const calloutMarker: MarkdownConfig = {
	// Its own node rather than swallowing it as plain text: a named node is what
	// lets the highlighter dim it as syntax, and what a future feature (folding,
	// a type autocomplete) would hang off.
	defineNodes: [{ name: "CalloutMarker", style: tags.processingInstruction }],
	parseInline: [
		{
			name: "CalloutMarker",
			before: "Link",
			parse(cx, next, pos) {
				// `cx.offset` is where this inline section starts, which for a
				// blockquote is AFTER the `> `. A callout marker is only a callout
				// marker at the very start of one — `[!note]` halfway down a
				// paragraph is prose, and Reading mode agrees.
				if (next !== OPEN_BRACKET || pos !== cx.offset) {
					return -1;
				}
				const match = MARKER.exec(cx.slice(pos, Math.min(cx.end, pos + MAX_MARKER)));
				if (!match) {
					return -1;
				}
				return cx.addElement(cx.elt("CalloutMarker", pos, pos + match[0].length));
			},
		},
	],
};
