import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { katexDecoration } from "./katex-decoration";

let view: EditorView;
afterEach(() => view?.destroy());

describe("katexDecoration", () => {
	test("renders inline math as a widget without changing the doc text", () => {
		const doc = "before $E=mc^2$ after\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [katexDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc); // view-only
		// A katex-rendered node exists in the DOM (widget mounted).
		expect(view.dom.querySelector(".katex, .cm-katex-widget")).not.toBeNull();
	});

	test("renders block math ($$...$$) as a widget", () => {
		const doc = "before\n\n$$a^2+b^2=c^2$$\n\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [katexDecoration] }),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelector(".cm-katex-widget")).not.toBeNull();
	});

	test("renders multi-line block math ($$\\n...\\n$$) without throwing", () => {
		// Regression: a ViewPlugin may not emit a replace decoration that spans a
		// line break — CM6 throws "Decorations that replace line breaks may not be
		// specified via plugins" on update. This multi-line block must render via a
		// StateField block widget. A single-line $$...$$ never exercised the rule.
		const doc = "before\n\n$$\n\\int_0^\\infty e^{-x}\\,dx = 1\n$$\n\nafter\n";
		view = new EditorView({
			state: EditorState.create({ doc, extensions: [katexDecoration] }),
			parent: document.body,
		});
		// Force an update cycle — the restriction is enforced at view-update time.
		view.dispatch({ changes: { from: 0, insert: "x" } });
		expect(view.state.doc.toString().endsWith("after\n")).toBe(true);
		expect(view.dom.querySelector(".cm-katex-widget")).not.toBeNull();
	});

	test("reveals raw source when the cursor is inside the math span", () => {
		const doc = "$E=mc^2$\n";
		view = new EditorView({
			state: EditorState.create({
				doc,
				selection: { anchor: 2 },
				extensions: [katexDecoration],
			}),
			parent: document.body,
		});
		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelector(".cm-katex-widget")).toBeNull();
	});
});
