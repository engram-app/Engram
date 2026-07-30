import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { mermaidDecoration } from "./mermaid-decoration";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string, anchor?: number) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [mermaidDecoration],
			...(anchor === undefined ? {} : { selection: { anchor } }),
		}),
		parent: document.body,
	});
	return view;
}

const FENCE = "```mermaid\ngraph LR\n  Edit --> Sync\n```";

describe("mermaidDecoration", () => {
	test("replaces a mermaid fence with a widget, leaving the document untouched", () => {
		// The whole extension is view-only: it decorates the source but must never
		// mutate EditorState.doc, or it would fight the yCollab Y.Text binding.
		const doc = `before\n\n${FENCE}\n\nafter\n`;
		mount(doc, 0);

		expect(view.state.doc.toString()).toBe(doc);
		expect(view.dom.querySelector(".cm-mermaid-widget")).not.toBeNull();
	});

	test("survives an update cycle, so the block decoration is legal", () => {
		// Regression guard for the same rule katex-decoration hit: a replace
		// decoration spanning a line break may not come from a ViewPlugin, and CM6
		// only enforces it at view-update time. A mermaid fence is ALWAYS
		// multi-line, so this extension has to be a StateField.
		const doc = `before\n\n${FENCE}\n\nafter\n`;
		mount(doc, 0);

		expect(() => view.dispatch({ changes: { from: 0, insert: "x" } })).not.toThrow();
		expect(view.state.doc.toString()).toBe(`xbefore\n\n${FENCE}\n\nafter\n`);
	});

	test("reveals the raw source while the cursor is inside the fence", () => {
		// Same reveal-on-cursor contract as callouts and math: you cannot edit a
		// diagram you cannot see.
		const doc = `before\n\n${FENCE}\n\nafter\n`;
		mount(doc, doc.indexOf("graph LR") + 2);

		expect(view.dom.querySelector(".cm-mermaid-widget")).toBeNull();
	});

	test("ignores fences in other languages", () => {
		mount("```ts\nconst a = 1;\n```\n", 0);
		expect(view.dom.querySelector(".cm-mermaid-widget")).toBeNull();
	});

	test("ignores an unterminated fence", () => {
		// Half-typed. Rendering while someone is still writing the opening line
		// would swallow the text they are typing into.
		mount("```mermaid\ngraph LR\n", 0);
		expect(view.dom.querySelector(".cm-mermaid-widget")).toBeNull();
	});

	test("decorates each of several fences independently", () => {
		// Caret parked on the prose BETWEEN them: anywhere inside either fence
		// would legitimately reveal that one as raw, which is the previous test.
		const doc = `${FENCE}\n\ntext\n\n${FENCE}\n`;
		mount(doc, doc.indexOf("text") + 1);
		expect(view.dom.querySelectorAll(".cm-mermaid-widget")).toHaveLength(2);
	});
});
