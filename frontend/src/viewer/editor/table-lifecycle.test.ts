import { tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test, vi } from "vitest";

// The widget attaches document-level listeners (box selection, handle drag,
// context menu). When the table is rebuilt (undo, a remote edit) or removed
// they must go with it, or they act on a detached table. Patched in
// patches/@atomic-editor%2Feditor@*.
//
//   idx:  0 1 2      a | b | c
//         3 4 5      1 | 2 | 3
//         6 7 8      4 | 5 | 6
const DOC = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n";
const OTHER = "| x | y |\n| --- | --- |\n| 9 | 8 |\n\nafter\n";

let view: EditorView;
afterEach(() => {
	vi.restoreAllMocks();
	view?.destroy();
	for (const m of document.querySelectorAll(".cm-atomic-table-menu")) {
		m.remove();
	}
});

function mount() {
	view = new EditorView({
		state: EditorState.create({
			doc: DOC,
			extensions: [markdown({ base: markdownLanguage }), tables({})],
		}),
		parent: document.body,
	});
}

const src = (i: number) =>
	view.dom
		.querySelectorAll(".cm-atomic-table th, .cm-atomic-table td")
		[i]?.querySelector(".cm-atomic-table-cell-source") as HTMLElement;

const replaceDoc = (doc: string) =>
	view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: doc } });

/** The event types `document.removeEventListener` was called with. */
const removedFromDocument = () => {
	const spy = vi.spyOn(document, "removeEventListener");
	return () => spy.mock.calls.map((c) => c[0]);
};

describe("a rebuilt table drops its document listeners", () => {
	test("box selection stops watching the document", () => {
		mount();
		const removed = removedFromDocument();
		const ptr = (el: Element, type: string, buttons: number) =>
			el.dispatchEvent(new MouseEvent(type, { bubbles: true, button: 0, buttons }));
		ptr(src(3), "pointerdown", 1);
		ptr(src(5), "pointermove", 1);
		ptr(src(5), "pointerup", 0);
		replaceDoc(OTHER);
		expect(removed()).toContain("keydown");
	});

	test("a handle drag in flight is cancelled", () => {
		mount();
		const removed = removedFromDocument();
		const handle = view.dom.querySelector(".cm-atomic-table-handle-col") as HTMLElement;
		handle.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, button: 0, buttons: 1 }));
		replaceDoc(OTHER);
		expect(removed()).toContain("pointerup");
	});

	test("an open context menu closes", () => {
		mount();
		src(4).dispatchEvent(
			new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 5, clientY: 5 }),
		);
		expect(document.querySelector(".cm-atomic-table-menu")).not.toBeNull();
		replaceDoc(OTHER);
		expect(document.querySelector(".cm-atomic-table-menu")).toBeNull();
	});
});
