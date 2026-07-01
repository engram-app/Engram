import { describe, it, expect, afterEach } from "vitest";
import * as Y from "yjs";
import { Awareness } from "y-protocols/awareness";
import { EditorView, runScopeHandlers } from "@codemirror/view";
import { historyField } from "@codemirror/commands";
import { buildEditorState } from "./note-editor";

// happy-dom CAN render a real CodeMirror EditorView (verified 2026-06-29).
// The earlier comment was a cautious assumption; the DOM stubs in test-setup.ts
// are sufficient for CodeMirror's layout queries.
describe("buildEditorState", () => {
	it("seeds the editor document from the Y.Text content", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		ytext.insert(0, "# Seeded heading\n\nbody text");
		const awareness = new Awareness(doc);

		const state = buildEditorState(ytext, awareness, false);

		expect(state.doc.toString()).toBe("# Seeded heading\n\nbody text");
	});

	it("produces an empty document when the Y.Text is empty", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);

		const state = buildEditorState(ytext, awareness, true);

		expect(state.doc.toString()).toBe("");
	});

	it("reflects all Y.Text content at build time (seed is current, not stale)", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);
		ytext.insert(0, "first");
		ytext.insert(ytext.length, " second");

		const state = buildEditorState(ytext, awareness, false);

		expect(state.doc.toString()).toBe("first second");
	});

	// RED with buggy code (history() installs historyField); GREEN after fix.
	it("does not install the native history field", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);

		const state = buildEditorState(ytext, awareness, false);

		// historyField is the StateField that @codemirror/commands history() adds.
		// When present it means Ctrl+Z routes to the offset-based native undo, which
		// reverts remote peers' edits and causes CRDT divergence.
		// state.field(field, false) returns undefined when the field is not installed.
		expect(state.field(historyField, false)).toBeUndefined();
	});
});

describe("CRDT undo behaviour (EditorView + yCollab)", () => {
	const views: EditorView[] = [];
	const parents: HTMLElement[] = [];
	afterEach(() => {
		for (const v of views) v.destroy();
		views.length = 0;
		for (const p of parents) p.parentNode?.removeChild(p);
		parents.length = 0;
	});

	// RED with buggy code: Ctrl+Z fires native history undo which reverts the
	// remote peers text and diverges. GREEN after fix: yUndoManagerKeymap takes
	// highest precedence, Y.UndoManager reverts only the local edit.
	it("Ctrl+Z reverts only the local edit and preserves remote peers text", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);

		const parent = document.createElement("div");
		document.body.appendChild(parent);
		parents.push(parent);

		const view = new EditorView({
			state: buildEditorState(ytext, awareness, false),
			parent,
		});
		views.push(view);

		// LOCAL edit: dispatch a plain insert transaction. ySync forwards it to
		// ytext with the syncConf origin so Y.UndoManager tracks it.
		view.dispatch({
			changes: { from: 0, insert: "L" },
		});
		expect(view.state.doc.toString()).toContain("L");

		// REMOTE edit: insert via ytext with a foreign origin. ySync observer
		// forwards it into the CM view but Y.UndoManager does NOT track it.
		doc.transact(() => {
			ytext.insert(ytext.length, "R");
		}, "remote-peer");
		expect(view.state.doc.toString()).toContain("L");
		expect(view.state.doc.toString()).toContain("R");

		// Simulate Ctrl+Z through the actual keymap dispatch (same path as user
		// pressing the key). runScopeHandlers resolves priority and fires whichever
		// binding wins -- native historyKeymap (buggy) or yUndoManagerKeymap (fix).
		const ctrlZ = new KeyboardEvent("keydown", {
			key: "z",
			code: "KeyZ",
			ctrlKey: true,
			metaKey: false,
			bubbles: true,
			cancelable: true,
		});
		runScopeHandlers(view, ctrlZ, "editor");

		// Remote text must survive undo; local text must be gone.
		expect(view.state.doc.toString()).not.toContain("L");
		expect(view.state.doc.toString()).toContain("R");

		// View and Y.Text must be converged (no divergence).
		expect(view.state.doc.toString()).toBe(ytext.toString());
	});
});
