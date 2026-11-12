import { Decoration } from "@codemirror/view";
import { COMMENT_DELIMS, type CommentKind, findOpener } from "../../lib/comments";
import { defineRenderer, inCodeBlock, searchForward, type TextRenderer } from "./render-core";

// Greys `%%…%%` and `<!-- … -->` comments while editing, like Obsidian's editing
// view; the reading view hides them (see note-view.tsx). View-only: a mark
// decoration, never a document change, so it is safe over the yCollab binding.
const commentMark = Decoration.mark({ class: "cm-comment" });

// A `<!-- -->` or `%%` prefix after a `>` quote marker is still a comment; the
// marker itself never opens one, so scanning from the line start is the same.
const QUOTE_PREFIX = /^(?: {0,3}>[ \t]?)*[ \t]*/u;

/**
 * Comments, one line at a time from a neutral line, through the same opener
 * rule the reading view uses (lib/comments.ts). Code blocks come from the
 * syntax tree, so the core rescans where the tree changes (`usesTree`). An
 * unclosed comment runs to the end of the note, as in Obsidian.
 */
export const commentRenderer: TextRenderer<CommentKind> = {
	kind: "text",
	usesTree: true,
	scan(state, from, emit, neutral, tree) {
		const { doc } = state;
		let resume = from; // a multi-line comment swallows the lines it spans
		for (let n = doc.lineAt(from).number; n <= doc.lines; n++) {
			const line = doc.line(n);
			if (line.from > from && line.from >= resume && neutral(line.from)) {
				return;
			}
			if (line.to <= resume && line.from < resume) {
				continue;
			}
			const body = QUOTE_PREFIX.exec(line.text)?.[0].length ?? 0;
			if (inCodeBlock(tree, line.from + body)) {
				continue;
			}
			let j = Math.max(body, resume - line.from);
			for (
				let open = findOpener(line.text, j, line.length);
				open;
				open = findOpener(line.text, j, line.length)
			) {
				const { open: o, close: c } = COMMENT_DELIMS[open.kind];
				const at = line.from + open.at;
				const close = searchForward(doc, at + o.length, c);
				const to = close < 0 ? doc.length : close + c.length;
				emit({ from: at, to, value: open.kind });
				resume = to;
				j = to - line.from;
			}
		}
	},
	decorate: (_state, t) => [commentMark.range(t.from, t.to)],
};

export const commentDecoration = defineRenderer(commentRenderer);
