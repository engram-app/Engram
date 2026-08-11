import { indentLess, indentMore } from "@codemirror/commands";
import type { EditorView } from "@codemirror/view";
import { IndentDecrease, IndentIncrease, List, Redo2, SquareCheckBig, Undo2 } from "lucide-react";
import { yUndoManagerKeymap } from "y-codemirror.next";
import { Button } from "@/components/ui/button";
import { useMediaQuery } from "@/hooks/use-media-query";
import { toggleCheckbox, toggleLinePrefix } from "./format-commands";
import { useEditorFocused } from "./use-editor-focused";
import { useKeyboardInset } from "./use-keyboard-inset";

/**
 * History lives in Yjs, not CodeMirror. The editor installs yCollab, which owns
 * a Y.UndoManager and binds it to Ctrl+Z / Ctrl+Y through yUndoManagerKeymap;
 * it does NOT install @codemirror/commands' history, so that package's `undo`
 * would find no history extension and silently do nothing.
 *
 * Run the keymap's own bindings rather than reaching for a manager directly.
 * The package does not export its undo/redo commands from its root and its
 * `exports` map blocks deep imports, and the one manager that IS reachable —
 * `ySyncFacet(...).undoManager` — is a decoy: YSyncConfig's constructor mints
 * its own Y.UndoManager, a DIFFERENT instance from the one yCollab registers
 * tracked origins on, so undo() on it silently does nothing against an empty
 * stack. Going through the keymap guarantees the same manager Ctrl+Z drives.
 */
function runBinding(key: string, view: EditorView): void {
	yUndoManagerKeymap.find((b) => b.key === key)?.run?.(view);
}

function undoEdit(view: EditorView): void {
	runBinding("Mod-z", view);
}

function redoEdit(view: EditorView): void {
	runBinding("Mod-y", view);
}

/**
 * The strip of editor actions docked above the on-screen keyboard, Obsidian's
 * mobile toolbar in miniature.
 *
 * Scope is deliberately the commands a soft keyboard CANNOT otherwise reach:
 * indent and outdent have no Tab key to bind to on a phone, and toggling a
 * checkbox by hand means typing six characters mid-line. Bold/italic are
 * omitted on purpose — `**` is two taps and already works.
 *
 * Mobile only, and only while the keyboard is actually up: on desktop the
 * markdown shortcuts and Tab/Shift-Tab already cover this, and a bar pinned
 * over the document with no keyboard under it is just lost height.
 */
export function KeyboardBar({ getView }: { getView: () => EditorView | null }) {
	const isDesktop = useMediaQuery("(min-width: 768px)");
	const focused = useEditorFocused();
	const inset = useKeyboardInset();

	// Gated on FOCUS, not on a non-zero inset. Browsers disagree about which
	// viewport the keyboard resizes: where the layout viewport shrinks too, the
	// inset is 0 with the keyboard fully open, and gating on it hid the bar
	// outright. Focus means the same thing on every browser; the inset is only
	// used to position.
	if (isDesktop || !focused) {
		return null;
	}

	const run = (fn: (v: EditorView) => void) => () => {
		const v = getView();
		if (v) {
			fn(v);
		}
	};

	return (
		<nav
			role="toolbar"
			aria-label="Editor actions"
			// Docked to the bottom of the layout viewport and lifted by the measured
			// inset. Where only the visual viewport shrank (iOS, Chrome 108+) the
			// inset is the keyboard height and this lifts clear of it; where the
			// layout viewport shrank too, the inset is 0 and bottom-0 is already
			// sitting on top of the keyboard. One expression covers both.
			className="fixed inset-x-0 bottom-0 z-40 flex items-center gap-1 border-border border-t bg-card px-2 py-1.5"
			style={{ transform: `translateY(-${inset}px)` }}
			// Keep the keyboard up. A pointerdown that reaches the document blurs
			// the editor, iOS dismisses the keyboard, and the bar this lives on
			// slides away mid-tap — so the press must never move focus.
			onPointerDown={(e) => e.preventDefault()}
		>
			<Button variant="ghost" size="icon" aria-label="Undo" onClick={run(undoEdit)}>
				<Undo2 className="size-5" />
			</Button>
			<Button variant="ghost" size="icon" aria-label="Redo" onClick={run(redoEdit)}>
				<Redo2 className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Outdent"
				onClick={run((v) => {
					indentLess(v);
				})}
			>
				<IndentDecrease className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Indent"
				onClick={run((v) => {
					indentMore(v);
				})}
			>
				<IndentIncrease className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Toggle checkbox"
				onClick={run(toggleCheckbox)}
			>
				<SquareCheckBig className="size-5" />
			</Button>
			<Button
				variant="ghost"
				size="icon"
				aria-label="Bullet list"
				onClick={run((v) => toggleLinePrefix(v, "- "))}
			>
				<List className="size-5" />
			</Button>
		</nav>
	);
}
