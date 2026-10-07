import { type EditorState, StateField } from "@codemirror/state";
import { Decoration, type DecorationSet, EditorView } from "@codemirror/view";
import { findComments } from "../../lib/comments";

// Greys `%%…%%` and `<!-- … -->` comments while editing, like Obsidian's editing
// view; the reading view hides them (see note-view.tsx). View-only: a mark
// decoration, never a document change, so it is safe over the yCollab binding.
const commentMark = Decoration.mark({ class: "cm-comment" });

function buildComments(state: EditorState): DecorationSet {
	return Decoration.set(
		findComments(state.doc.toString()).map((c) => commentMark.range(c.from, c.to)),
		true,
	);
}

// StateField, not a ViewPlugin: whether a `%%` is a comment depends on the whole
// document (code fences, an earlier unclosed `%%`), not just the visible range.
export const commentDecoration = StateField.define<DecorationSet>({
	create: buildComments,
	update(deco, tr) {
		return tr.docChanged ? buildComments(tr.state) : deco;
	},
	provide: (f) => EditorView.decorations.from(f),
});
