import type { EditorView } from "@codemirror/view";
import { createContext, type ReactNode, useCallback, useContext, useMemo, useState } from "react";

// Publishes the currently-mounted markdown editor to UI rendered OUTSIDE the
// note page — specifically the right-sidebar tool panels, which AppLayout owns
// as a SIBLING of the <Outlet/> that renders NotePage. EditorToolbar can just
// close over NotePage's `editorViewRef` because it lives inside NotePage; the
// reference panel cannot, hence this context.
//
// Deliberately NOT reactive on the view itself: consumers only need the view at
// the moment the user clicks Insert, and re-rendering every panel on each
// CodeMirror view swap would be pure waste. `hasEditor` is the one reactive bit,
// because "is there somewhere to insert into" drives disabled states.

interface ActiveEditor {
	/** The live editor view, or null when none is mounted (dashboard, reading mode, attachments). */
	getView: () => EditorView | null;
	/**
	 * Publish the active editor accessor, or null to clear it. Only the note page
	 * should call this, from an effect keyed on whether the editor is rendered.
	 */
	setEditor: (getView: (() => EditorView | null) | null) => void;
	/** True while an editor is mounted. Drives disabled states on editor-targeted actions. */
	hasEditor: boolean;
}

const Ctx = createContext<ActiveEditor | null>(null);

export function ActiveEditorProvider({ children }: { children: ReactNode }) {
	const [getter, setGetter] = useState<(() => EditorView | null) | null>(null);

	// Stored via the functional-update form: a bare setGetter(fn) would have
	// React CALL fn as a state updater instead of storing it.
	const setEditor = useCallback((next: (() => EditorView | null) | null) => {
		setGetter(() => next);
	}, []);

	const value = useMemo<ActiveEditor>(
		() => ({
			getView: () => getter?.() ?? null,
			setEditor,
			hasEditor: getter !== null,
		}),
		[getter, setEditor],
	);

	return <Ctx.Provider value={value}>{children}</Ctx.Provider>;
}

export function useActiveEditor(): ActiveEditor {
	const ctx = useContext(Ctx);
	if (!ctx) {
		throw new Error("useActiveEditor must be used inside ActiveEditorProvider");
	}
	return ctx;
}
