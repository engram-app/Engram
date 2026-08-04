import { closeBrackets, closeBracketsKeymap } from "@codemirror/autocomplete";
import { defaultKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { defaultHighlightStyle, syntaxHighlighting } from "@codemirror/language";
import { Compartment, EditorState, Prec } from "@codemirror/state";
import { oneDarkTheme } from "@codemirror/theme-one-dark";
import { drawSelection, EditorView, keymap } from "@codemirror/view";
import { useEffect, useRef } from "react";
import { yCollab, yUndoManagerKeymap } from "y-codemirror.next";
import type { Awareness } from "y-protocols/awareness";
import type * as Y from "yjs";
import { useTheme } from "../theme/theme-provider";
import { indentKeymap } from "./editor/format-commands";
import { frontmatterShortcut } from "./editor/frontmatter-shortcut";
import { livePreviewExtensions } from "./editor/live-preview";

// height:auto + overflow:visible hand scrolling to the page's ScrollArea, so
// the inline title and properties scroll with the text instead of staying
// pinned above it. CodeMirror still viewport-renders against the scrolling
// ancestor. 16px on .cm-content prevents iOS Safari auto-zoom. Transparent
// background so the card shows through.
const editorTheme = EditorView.theme({
	"&": { height: "auto", backgroundColor: "transparent" },
	".cm-scroller": {
		fontFamily: "inherit",
		// Inert while the page owns the scrollbar; the styling rules below are
		// likewise inert but cost nothing and matter again if this is reverted.
		overflow: "visible",
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

export type EditorMode = "rendered" | "raw";

export interface NoteEditorProps {
	ytext: Y.Text;
	awareness: Awareness;
	mode: EditorMode;
	resolveWikiLink: (name: string) => string;
	/** Click-to-open a wikilink target — router-navigates from the React tree. */
	openWikiLink: (name: string) => void;
	/** Vault-wide note paths for `[[` autocomplete (see editor/wiki-completion.ts). */
	wikiCompletionPaths: () => string[];
	/** Reaches the live EditorView out to a caller (e.g. the formatting toolbar). */
	onView?: (view: EditorView | null) => void;
	/**
	 * `---` was typed on the first line. Return true to accept the gesture, in
	 * which case the fence is removed from the body; false leaves it as an
	 * ordinary horizontal rule. See `editor/frontmatter-shortcut`.
	 */
	onFrontmatterShortcut?: () => boolean;
}

// One shared compartment instance: reconfiguring it swaps the decoration layer
// without recreating the view, so yCollab stays attached to the same Y.Text.
// The base extensions (below) NEVER include a markdown language -- the
// compartment is the ONLY source of the markdown grammar, in both modes, so
// creating the view in either mode and later switching leaves the doc with a
// working language either way.
export const decorationsCompartment = new Compartment();

/**
 * The per-mode compartment payload. Rendered mode gets the full live-preview
 * extension set (markdown language + atomic decorations); raw mode gets a
 * plain markdown language only, no decorations. Exported so tests can drive
 * `decorationsCompartment.reconfigure(...)` directly against a mounted view.
 */
export function decorationsFor(
	mode: EditorMode,
	resolveWikiLink: (name: string) => string,
	openWikiLink: (name: string) => void,
	wikiCompletionPaths: () => string[],
) {
	return mode === "rendered"
		? livePreviewExtensions({ resolveWikiLink, openWikiLink, wikiCompletionPaths })
		: [markdown({ base: markdownLanguage })];
}

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
export function buildEditorState(
	ytext: Y.Text,
	awareness: Awareness,
	dark: boolean,
	mode: EditorMode,
	resolveWikiLink: (name: string) => string,
	openWikiLink: (name: string) => void,
	wikiCompletionPaths: () => string[],
	onFrontmatterShortcut?: () => boolean,
): EditorState {
	return EditorState.create({
		doc: ytext.toString(),
		extensions: [
			...(onFrontmatterShortcut ? [frontmatterShortcut(onFrontmatterShortcut)] : []),
			drawSelection(),
			EditorView.lineWrapping,
			Prec.highest(keymap.of(yUndoManagerKeymap)),
			// Obsidian/VS Code-style bracket behavior: typing ( [ { ' " ` inserts
			// the closer, typing the closer over an auto-inserted one skips it,
			// and typing an opener with a selection SURROUNDS the selection
			// instead of replacing it. The keymap makes Backspace delete an
			// empty pair; it must sit before defaultKeymap to win the key.
			closeBrackets(),
			keymap.of(closeBracketsKeymap),
			// closeBrackets reads its bracket set from languageData; markdown
			// declares none, so provide one everywhere — the default set plus
			// backtick (inline code is a first-class markdown pairing).
			EditorState.languageData.of(() => [
				{ closeBrackets: { brackets: ["(", "[", "{", "'", '"', "`"] } },
			]),
			keymap.of(defaultKeymap),
			// Tab/Shift-Tab indent-dedent (Obsidian parity). Base, not the mode
			// compartment, so it works in both rendered and raw mode.
			indentKeymap,
			// Highlight style for the markdown grammar tags -- kept in base (not the
			// compartment) so raw mode is highlighted too; harmless in rendered mode
			// since atomicMarkdownSyntax layers its own token colors on top.
			syntaxHighlighting(defaultHighlightStyle, { fallback: true }),
			// oneDarkTheme = the dark editor chrome ONLY (caret, selection, gutters).
			// We deliberately do NOT use the bundled `oneDark`, which also ships
			// oneDarkHighlightStyle and colors headings/tokens with One Dark's palette
			// (e.g. headings #e06c75 red) -- that overrode the Obsidian text color.
			// atomicMarkdownSyntax + the --atomic-editor-* vars own token colors now.
			...(dark ? [oneDarkTheme] : []),
			// Prec.highest so the transparent background + layout beat any theme's
			// own surface color (the dark theme sets its own background otherwise).
			Prec.highest(editorTheme),
			// The ONLY source of the markdown language: swapping this compartment is
			// what toggles Rendered vs Raw mode. See decorationsFor above.
			decorationsCompartment.of(
				decorationsFor(mode, resolveWikiLink, openWikiLink, wikiCompletionPaths),
			),
			// yCollab keeps the view and Y.Text in sync AFTER this initial seed and
			// wires local edits back into the Y.Text (→ CRDT channel). MUST stay in
			// the base extensions (never in the compartment) -- reconfiguring the
			// compartment on mode switch must never detach this binding.
			yCollab(ytext, awareness),
		],
	});
}

// Uncontrolled raw EditorView: yCollab owns the document. We do NOT use
// @uiw/react-codemirror here — it is a controlled wrapper that re-dispatches a
// doc replace whenever its `value` prop differs from the editor content, which
// fights yCollab and clobbers concurrent edits. A directly-managed view sidesteps
// that entirely.
export default function NoteEditor({
	ytext,
	awareness,
	mode,
	resolveWikiLink,
	openWikiLink,
	wikiCompletionPaths,
	onView,
	onFrontmatterShortcut,
}: NoteEditorProps) {
	const { resolved } = useTheme();
	const hostRef = useRef<HTMLDivElement>(null);
	const viewRef = useRef<EditorView | null>(null);
	// Ref-style callback: always holds the latest onView without being an effect
	// dependency, so a caller re-rendering with a new onView identity never
	// recreates the view.
	const onViewRef = useRef(onView);
	onViewRef.current = onView;
	// Same treatment: the extension is baked into the state at creation, so it
	// must read through a ref or a new callback identity would force a rebuild
	// and detach yCollab.
	const onShortcutRef = useRef(onFrontmatterShortcut);
	onShortcutRef.current = onFrontmatterShortcut;

	// Create the view only when the bound doc or theme changes (NOT on mode).
	// mode/resolveWikiLink intentionally excluded: a mode switch must reconfigure
	// the decorationsCompartment on the existing view (below), never recreate it
	// -- recreating here would detach yCollab and re-seed the doc on every toggle.
	// onView intentionally excluded too (read via onViewRef): it's an escape
	// hatch for the toolbar, not a doc/theme dependency -- including it would
	// tear down and recreate the view (yCollab-detach hazard) whenever the
	// caller passes a differently-identitied callback.
	// biome-ignore lint/correctness/useExhaustiveDependencies: mode/resolveWikiLink/openWikiLink/wikiCompletionPaths/onView are intentionally excluded, see comment above.
	useEffect(() => {
		const parent = hostRef.current;
		if (!parent) {
			return;
		}
		const view = new EditorView({
			state: buildEditorState(
				ytext,
				awareness,
				resolved === "dark",
				mode,
				resolveWikiLink,
				openWikiLink,
				wikiCompletionPaths,
				() => Boolean(onShortcutRef.current?.()),
			),
			parent,
		});
		viewRef.current = view;
		onViewRef.current?.(view);
		return () => {
			view.destroy();
			viewRef.current = null;
			onViewRef.current?.(null);
		};
	}, [ytext, awareness, resolved]);

	// Swap the decoration layer live when mode changes — view stays, yCollab stays.
	useEffect(() => {
		const view = viewRef.current;
		if (!view) {
			return;
		}
		view.dispatch({
			effects: decorationsCompartment.reconfigure(
				decorationsFor(mode, resolveWikiLink, openWikiLink, wikiCompletionPaths),
			),
		});
	}, [mode, resolveWikiLink, openWikiLink, wikiCompletionPaths]);

	return <div ref={hostRef} />;
}
