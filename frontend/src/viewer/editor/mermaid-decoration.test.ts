import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";
import { enterMermaidDown, enterMermaidUp, mermaidDecoration } from "./mermaid-decoration";

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

	// before\n        0..6   (line 1)
	// ```mermaid\n    7..17  (line 2, fence opens)
	// graph LR\n      18..26 (line 3)
	//   A --> B\n     27..36 (line 4)
	// ```\n           37..40 (line 5, fence closes)
	// after\n         41..46 (line 6)
	const NAV = "before\n```mermaid\ngraph LR\n  A --> B\n```\nafter\n";

	describe("entering a rendered block with the arrow keys", () => {
		// A block replace leaves NO visible position inside it, so CM6's vertical
		// motion steps straight over the whole diagram: measured in a real editor,
		// ArrowDown from the line above a fence landed on the line BELOW it, and
		// ArrowUp from below landed above. The block was unreachable by keyboard —
		// only a click could open it. These commands put the caret on the fence
		// instead, which reveals the source, exactly as arrowing into a callout does.

		test("ArrowDown from the line above lands on the fence, not past it", () => {
			mount(NAV, 0);
			expect(enterMermaidDown(view)).toBe(true);
			expect(view.state.selection.main.head).toBe(7);
		});

		test("ArrowUp from the line below lands on the closing fence", () => {
			mount(NAV, 41);
			expect(enterMermaidUp(view)).toBe(true);
			// End of the closing fence, so continuing upward walks the source.
			expect(view.state.selection.main.head).toBe(40);
		});

		test("defers to normal motion once the caret is already inside", () => {
			// Otherwise the caret would be pinned to the fence and could never
			// traverse the diagram's own lines.
			mount(NAV, 20);
			expect(enterMermaidDown(view)).toBe(false);
			expect(enterMermaidUp(view)).toBe(false);
		});

		test("defers to normal motion when no fence is adjacent", () => {
			mount("just prose\nand more prose\n", 0);
			expect(enterMermaidDown(view)).toBe(false);
			expect(enterMermaidUp(view)).toBe(false);
		});

		test("defers when the selection is a range, not a caret", () => {
			// Shift+Arrow is selecting, not navigating; hijacking it would collapse
			// the user's selection.
			view = new EditorView({
				state: EditorState.create({
					doc: NAV,
					selection: { anchor: 0, head: 3 },
					extensions: [mermaidDecoration],
				}),
				parent: document.body,
			});
			expect(enterMermaidDown(view)).toBe(false);
		});
	});

	test("decorates each of several fences independently", () => {
		// Caret parked on the prose BETWEEN them: anywhere inside either fence
		// would legitimately reveal that one as raw, which is the previous test.
		const doc = `${FENCE}\n\ntext\n\n${FENCE}\n`;
		mount(doc, doc.indexOf("text") + 1);
		expect(view.dom.querySelectorAll(".cm-mermaid-widget")).toHaveLength(2);
	});
});
