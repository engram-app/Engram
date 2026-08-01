import { tags } from "@lezer/highlight";
import type { MarkdownConfig } from "@lezer/markdown";

const MARKER = /^\[!\w+\][+-]?/;

// `[` — the only character worth waking this parser up for.
const OPEN_BRACKET = 91;

// Longest real type is "attention" (9). 32 bounds the scan without ruling out a
// type the library might add.
const MAX_MARKER = 32;

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
 *
 * The rule is "at the start of an inline section", which in a blockquote is
 * after the `> `. That also claims `[!note]` opening a PLAIN paragraph, where
 * it is not a callout — but Reading mode renders that as the literal text
 * `[!note]` too, so matching it here is the behaviour that agrees with the
 * other pane. What it must never claim is a bracket further into a line, which
 * really can be a link.
 */
export const calloutMarker: MarkdownConfig = {
	// Its own node rather than swallowing it as plain text: a named node is what
	// lets the highlighter dim it as syntax, and what a future feature (folding,
	// a type autocomplete) would hang off.
	//
	// special(), NOT bare processingInstruction. Lezer gives that ONE tag to
	// HeaderMark, QuoteMark, ListMark, LinkMark, EmphasisMark, CodeMark,
	// TableDelimiter and more, so a Prec.highest rule targeting it repaints every
	// syntax mark in the editor — the exact trap `t.monospace` already sprang on
	// this file's neighbour. A special() variant is distinguishable by a rule
	// that asks for it, and still falls back to the plain tag for any rule that
	// does not.
	defineNodes: [{ name: "CalloutMarker", style: tags.special(tags.processingInstruction) }],
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
