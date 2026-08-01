import { historyField } from "@codemirror/commands";
import { EditorView, runScopeHandlers } from "@codemirror/view";
import { afterEach, describe, expect, it } from "vitest";
import { Awareness } from "y-protocols/awareness";
import * as Y from "yjs";
import { buildEditorState, decorationsCompartment, decorationsFor } from "./note-editor";

const resolveWikiLink = (n: string) => `/notes/${n}`;

// happy-dom CAN render a real CodeMirror EditorView (verified 2026-06-29).
// The earlier comment was a cautious assumption; the DOM stubs in test-setup.ts
// are sufficient for CodeMirror's layout queries.
describe("buildEditorState", () => {
	it("seeds the editor document from the Y.Text content", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		ytext.insert(0, "# Seeded heading\n\nbody text");
		const awareness = new Awareness(doc);

		const state = buildEditorState(ytext, awareness, false, "rendered", resolveWikiLink);

		expect(state.doc.toString()).toBe("# Seeded heading\n\nbody text");
	});

	it("produces an empty document when the Y.Text is empty", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);

		const state = buildEditorState(ytext, awareness, true, "rendered", resolveWikiLink);

		expect(state.doc.toString()).toBe("");
	});

	it("reflects all Y.Text content at build time (seed is current, not stale)", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);
		ytext.insert(0, "first");
		ytext.insert(ytext.length, " second");

		const state = buildEditorState(ytext, awareness, false, "rendered", resolveWikiLink);

		expect(state.doc.toString()).toBe("first second");
	});

	// RED with buggy code (history() installs historyField); GREEN after fix.
	it("does not install the native history field", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		const awareness = new Awareness(doc);

		const state = buildEditorState(ytext, awareness, false, "rendered", resolveWikiLink);

		// historyField is the StateField that @codemirror/commands history() adds.
		// When present it means Ctrl+Z routes to the offset-based native undo, which
		// reverts remote peers' edits and causes CRDT divergence.
		// state.field(field, false) returns undefined when the field is not installed.
		expect(state.field(historyField, false)).toBeUndefined();
	});

	it("rendered mode installs decorations; raw mode installs none, doc unchanged", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		ytext.insert(0, "# H\n\n**b**\n");
		const awareness = new Awareness(doc);

		const rendered = buildEditorState(ytext, awareness, false, "rendered", resolveWikiLink);
		const raw = buildEditorState(ytext, awareness, false, "raw", resolveWikiLink);

		// Both seed identical, unaltered doc bytes (view-only decorations).
		expect(rendered.doc.toString()).toBe("# H\n\n**b**\n");
		expect(raw.doc.toString()).toBe("# H\n\n**b**\n");
		// The compartment holds content in both modes (a markdown language in raw,
		// the fuller live-preview extension set in rendered) -- never undefined.
		expect(decorationsCompartment.get(rendered)).not.toBeUndefined();
		expect(decorationsCompartment.get(raw)).not.toBeUndefined();
	});
});

describe("CRDT undo behaviour (EditorView + yCollab)", () => {
	const views: EditorView[] = [];
	const parents: HTMLElement[] = [];
	afterEach(() => {
		for (const v of views) {
			v.destroy();
		}
		views.length = 0;
		for (const p of parents) {
			p.parentNode?.removeChild(p);
		}
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
			state: buildEditorState(ytext, awareness, false, "rendered", resolveWikiLink),
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

describe("mode switch via decorationsCompartment.reconfigure (yCollab must survive)", () => {
	const views: EditorView[] = [];
	const parents: HTMLElement[] = [];
	afterEach(() => {
		for (const v of views) {
			v.destroy();
		}
		views.length = 0;
		for (const p of parents) {
			p.parentNode?.removeChild(p);
		}
		parents.length = 0;
	});

	it("reconfiguring rendered -> raw is view-only and leaves yCollab attached", () => {
		const doc = new Y.Doc();
		const ytext = doc.getText("content");
		ytext.insert(0, "# H\n\n**b**\n");
		const awareness = new Awareness(doc);

		const parent = document.createElement("div");
		document.body.appendChild(parent);
		parents.push(parent);

		const view = new EditorView({
			state: buildEditorState(ytext, awareness, false, "rendered", resolveWikiLink),
			parent,
		});
		views.push(view);

		const before = view.state.doc.toString();

		// Simulate the mode-switch effect: reconfigure the SAME compartment on the
		// SAME view -- this must never recreate the view or detach yCollab.
		view.dispatch({
			effects: decorationsCompartment.reconfigure(decorationsFor("raw", resolveWikiLink)),
		});

		// (a) View-only: doc bytes are byte-identical after the switch.
		expect(view.state.doc.toString()).toBe(before);
		expect(view.state.doc.toString()).toBe("# H\n\n**b**\n");

		// (b) yCollab is still bound: a remote Y.Text edit (foreign origin, the
		// same pattern the CRDT undo test above uses) must still flow into the view.
		doc.transact(() => {
			ytext.insert(ytext.length, "tail");
		}, "remote-peer");
		expect(view.state.doc.toString()).toBe(ytext.toString());
		expect(view.state.doc.toString()).toContain("tail");
	});
});
