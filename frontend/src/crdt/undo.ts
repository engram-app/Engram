import * as Y from "yjs";
import {
	CONTENT_KEY,
	FRONTMATTER_KEY,
	ORDER_KEY,
	RAW_FRONTMATTER_KEY,
	TYPES_KEY,
} from "./frontmatter-doc";

const managers = new WeakMap<Y.Doc, Y.UndoManager>();

// Inputs that keep their own native undo for the text being typed.
const NON_TEXT_INPUTS = new Set([
	"checkbox",
	"radio",
	"button",
	"submit",
	"reset",
	"date",
	"datetime-local",
	"color",
	"range",
	"file",
]);

function isTextEntry(el: EventTarget | null): boolean {
	if (!(el instanceof HTMLElement)) {
		return false;
	}
	if (el instanceof HTMLTextAreaElement || el.isContentEditable) {
		return true;
	}
	return el instanceof HTMLInputElement && !NON_TEXT_INPUTS.has(el.type);
}

/**
 * The note's one undo history: body text AND every frontmatter type, so Ctrl+Z
 * walks back a property edit the same as a typed word, in the order they were
 * made. The editor hands this to yCollab (so its Ctrl+Z keymap and the mobile
 * keyboard bar drive it), and the note page's document keydown listener
 * (undoKeyHandler) drives it everywhere else, so both reach the SAME stack.
 * Keyed on the doc; dies with it.
 *
 * Tracks the default `null` origin, which is what local `doc.transact` and the
 * editor's sync origin (added by yCollab) produce. Remote updates arrive with
 * a provider origin and are never captured.
 */
export function undoManagerFor(doc: Y.Doc): Y.UndoManager {
	let um = managers.get(doc);
	if (!um) {
		um = new Y.UndoManager([
			doc.getText(CONTENT_KEY),
			doc.getMap(FRONTMATTER_KEY),
			doc.getArray(ORDER_KEY),
			doc.getMap(TYPES_KEY),
			doc.getMap(RAW_FRONTMATTER_KEY),
		]);
		managers.set(doc, um);
	}
	return um;
}

/**
 * Document keydown listener for Ctrl/Cmd+Z, Ctrl/Cmd+Shift+Z and Ctrl/Cmd+Y
 * when focus is NOT in a text field: after removing a tag chip, ticking a
 * checkbox, or with nothing focused. The editor handles its own keys (and
 * marks them handled), and a property text field keeps native undo for the
 * characters being typed.
 */
// The chords mirror y-codemirror.next's yUndoManagerKeymap (Mod-z, Mod-y,
// Mod-Shift-z), which the editor binds; keep the two in step.
export function undoKeyHandler(doc: Y.Doc): (e: KeyboardEvent) => void {
	return (e) => {
		if (e.defaultPrevented || !(e.ctrlKey || e.metaKey) || e.altKey || isTextEntry(e.target)) {
			return;
		}
		const key = e.key.toLowerCase();
		const redo = key === "y" || (key === "z" && e.shiftKey);
		if (key !== "z" && key !== "y") {
			return;
		}
		e.preventDefault();
		const um = undoManagerFor(doc);
		if (redo) {
			um.redo();
		} else {
			um.undo();
		}
	};
}
