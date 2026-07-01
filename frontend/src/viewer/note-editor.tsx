import { defaultKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { defaultHighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { EditorState, Prec } from "@codemirror/state";
import { oneDark } from "@codemirror/theme-one-dark";
import { drawSelection, EditorView, keymap } from "@codemirror/view";
import { useEffect, useRef } from "react";
import { yCollab, yUndoManagerKeymap } from "y-codemirror.next";
import type { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { useTheme } from "../theme/theme-provider";

export interface NoteEditorProps {
	ytext: Y.Text;
	awareness: Awareness;
}

// Fill the parent so the editor spans the full pane height. 16px on .cm-content
// prevents iOS Safari auto-zoom. Transparent background so the card shows through.
const editorTheme = EditorView.theme({
	"&": { height: "100%", backgroundColor: "transparent" },
	".cm-scroller": {
		fontFamily: "inherit",
		overflow: "auto",
		backgroundColor: "transparent",
		scrollbarWidth: "thin",
		scrollbarColor: "var(--border) transparent",
	},
	".cm-scroller::-webkit-scrollbar": { width: "10px", height: "10px" },
	".cm-scroller::-webkit-scrollbar-track": { backgroundColor: "transparent" },
	".cm-scroller::-webkit-scrollbar-thumb": {
		backgroundColor: "var(--border)",
		borderRadius: "9999px",
		border: "1px solid transparent",
		backgroundClip: "padding-box",
	},
	".cm-gutters": { backgroundColor: "transparent", border: "none" },
	".cm-content": { fontSize: "16px", padding: "20px 20px 30vh" },
});

/**
 * Build the initial EditorState for a CRDT-bound editor.
 *
 * CRITICAL: `doc` MUST be seeded with `ytext.toString()`. y-codemirror.next's
 * ySync plugin only forwards INCREMENTAL Y.Text deltas into the view — it does
 * not insert content that already exists in the Y.Text when the binding
 * attaches. So an editor created with an empty doc against a non-empty Y.Text
 * (loaded from IndexedDB, or a STEP2 that landed before mount) renders blank
 * forever. Seeding the doc to the current Y.Text content is the canonical
 * yCollab setup and the fix for the "editor is empty but the note has content"
 * bug. Exported so it can be unit-tested without a DOM (EditorState is pure).
 */
export function buildEditorState(ytext: Y.Text, awareness: Awareness, dark: boolean): EditorState {
	return EditorState.create({
		doc: ytext.toString(),
		extensions: [
			drawSelection(),
			EditorView.lineWrapping,
			Prec.highest(keymap.of(yUndoManagerKeymap)),
			keymap.of(defaultKeymap),
			markdown({ base: markdownLanguage }),
			syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
			...(dark ? [oneDark] : []),
			// Prec.highest so the transparent background + layout beat any theme's
			// own surface color (oneDark sets its own background otherwise).
			Prec.highest(editorTheme),
			// yCollab keeps the view and Y.Text in sync AFTER this initial seed and
			// wires local edits back into the Y.Text (→ CRDT channel).
			yCollab(ytext, awareness),
		],
	});
}

// Uncontrolled raw EditorView: yCollab owns the document. We do NOT use
// @uiw/react-codemirror here — it is a controlled wrapper that re-dispatches a
// doc replace whenever its `value` prop differs from the editor content, which
// fights yCollab and clobbers concurrent edits. A directly-managed view sidesteps
// that entirely.
export default function NoteEditor({ ytext, awareness }: NoteEditorProps) {
	const { resolved } = useTheme();
	const hostRef = useRef<HTMLDivElement>(null);

	useEffect(() => {
		const parent = hostRef.current;
		if (!parent) return;
		const view = new EditorView({
			state: buildEditorState(ytext, awareness, resolved === "dark"),
			parent,
		});
		return () => view.destroy();
		// Recreate the view when the bound doc (note switch) or theme changes; the
		// new state re-seeds from ytext.toString() so content is never lost.
	}, [ytext, awareness, resolved]);

	return <div ref={hostRef} className="h-full" />;
}
