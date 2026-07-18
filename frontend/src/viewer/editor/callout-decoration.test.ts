import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { calloutDecoration } from "./callout-decoration";

let view: EditorView;
afterEach(() => view?.destroy());

describe("calloutDecoration", () => {
	test("marks a callout block's lines without changing the doc text", () => {
		const doc = "before\n\n> [!note] Title\n> body line\n\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc); // view-only
		const marked = view.dom.querySelectorAll(".cm-callout.cm-callout-note");
		expect(marked.length).toBe(2); // title line + body line
	});

	test("lowercases the callout type for the class name", () => {
		const doc = "intro\n\n> [!WARNING] Careful\n> details\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelectorAll(".cm-callout-warning").length).toBe(2);
	});

	test("reveals raw source when the selection intersects the callout block", () => {
		const doc = "> [!note] Title\n> body line\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 5 },
				extensions: [calloutDecoration],
			}),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelectorAll(".cm-callout").length).toBe(0);
	});

	test("does not merge two adjacent callouts with no blank line between them", () => {
		const doc = "before\n\n> [!note] A\n> body\n> [!warning] B\n> body2\n\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [calloutDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc); // view-only
		expect(view.dom.querySelectorAll(".cm-callout-note").length).toBe(2);
		expect(view.dom.querySelectorAll(".cm-callout-warning").length).toBe(2);
	});
});
