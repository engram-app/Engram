import { readOnlyExtension, tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Hover handles in the gutter left of each row and above each column; dragging
// one onto another row / column reorders it. Patched in
// patches/@atomic-editor%2Feditor@*.
//
//   idx:  0 1 2      a | b | c
//         3 4 5      1 | 2 | 3
//         6 7 8      4 | 5 | 6
const DOC = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc = DOC, readOnly = false) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [
				markdown({ base: markdownLanguage }),
				tables({}),
				...(readOnly ? [readOnlyExtension(true)] : []),
			],
		}),
		parent: document.body,
	});
}

const table = () => view.state.doc.toString().split("\n\nafter")[0] ?? "";
const cells = () =>
	Array.from(view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table th, .cm-atomic-table td"));
const colHandles = () =>
	Array.from(view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table-handle-col"));
const rowHandles = () =>
	Array.from(view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table-handle-row"));

function ptr(target: Element, type: string, init: MouseEventInit = {}) {
	const Ctor = typeof PointerEvent === "undefined" ? MouseEvent : PointerEvent;
	target.dispatchEvent(
		new Ctor(type, { bubbles: true, cancelable: true, button: 0, buttons: 1, ...init }),
	);
}

function src(i: number): HTMLElement {
	const el = cells()[i]?.querySelector<HTMLElement>(".cm-atomic-table-cell-source");
	if (!el) {
		throw new Error(`no cell ${i}`);
	}
	return el;
}

/** Press `handle`, drag over cell `over`, release there. */
function dragHandle(handle: HTMLElement | undefined, over: number) {
	if (!handle) {
		throw new Error("no handle");
	}
	ptr(handle, "pointerdown");
	ptr(src(over), "pointermove");
	ptr(src(over), "pointerup", { buttons: 0 });
}

describe("reorder handles", () => {
	test("each column and each body row gets one; the header row gets none", () => {
		mount();
		expect(colHandles()).toHaveLength(3);
		expect(rowHandles()).toHaveLength(2);
		expect(colHandles().map((h) => h.getAttribute("aria-label"))).toEqual([
			"Move column",
			"Move column",
			"Move column",
		]);
		expect(rowHandles()[0]?.getAttribute("aria-label")).toBe("Move row");
	});

	test("column handles sit in the header cells, row handles in the first column", () => {
		mount();
		expect(colHandles().every((h) => h.parentElement?.tagName === "TH")).toBe(true);
		expect(rowHandles().map((h) => cells().indexOf(h.parentElement as HTMLElement))).toEqual([
			3, 6,
		]);
	});

	test("a read-only table has none", () => {
		mount(DOC, true);
		expect(colHandles()).toHaveLength(0);
		expect(rowHandles()).toHaveLength(0);
	});

	test("handles do not change a cell's text or what gets serialized", () => {
		mount();
		expect(cells()[0]?.querySelector(".cm-atomic-table-cell-source")?.textContent).toBe("a");
		expect(view.dom.querySelectorAll(".cm-atomic-table th, .cm-atomic-table td")).toHaveLength(9);
	});
});

describe("dragging a column handle", () => {
	test("onto a column to its right moves the column there", () => {
		mount();
		dragHandle(colHandles()[0], 2);
		expect(table()).toBe("| b | c | a |\n| --- | --- | --- |\n| 2 | 3 | 1 |\n| 5 | 6 | 4 |");
	});

	test("onto a column to its left moves the column there", () => {
		mount();
		dragHandle(colHandles()[2], 3); // cell 3 is column 0
		expect(table()).toBe("| c | a | b |\n| --- | --- | --- |\n| 3 | 1 | 2 |\n| 6 | 4 | 5 |");
	});

	test("dropping on its own column changes nothing", () => {
		mount();
		const before = view.state.doc.toString();
		dragHandle(colHandles()[1], 4);
		expect(view.state.doc.toString()).toBe(before);
	});

	test("the column's alignment travels with it", () => {
		mount("| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |\n\nafter\n");
		dragHandle(colHandles()[0], 2);
		expect(table()).toBe("| b | c | a |\n| :---: | ---: | :--- |\n| 2 | 3 | 1 |");
	});

	test("handles are rebuilt on the right cells afterwards", () => {
		mount();
		dragHandle(colHandles()[0], 2);
		expect(colHandles()).toHaveLength(3);
		expect(rowHandles().map((h) => cells().indexOf(h.parentElement as HTMLElement))).toEqual([
			3, 6,
		]);
	});
});

describe("dragging a row handle", () => {
	test("onto a row below moves the row there", () => {
		mount();
		dragHandle(rowHandles()[0], 6);
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("onto a row above moves the row there", () => {
		mount();
		dragHandle(rowHandles()[1], 3);
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("the header row is not a drop target", () => {
		mount();
		const before = view.state.doc.toString();
		dragHandle(rowHandles()[0], 1); // a header cell
		expect(view.state.doc.toString()).toBe(before);
	});

	test("dropping on its own row changes nothing", () => {
		mount();
		const before = view.state.doc.toString();
		dragHandle(rowHandles()[0], 4);
		expect(view.state.doc.toString()).toBe(before);
	});
});

describe("while dragging", () => {
	test("the target column is marked, and the mark is removed on drop", () => {
		mount();
		ptr(colHandles()[0] as HTMLElement, "pointerdown");
		ptr(src(2), "pointermove");
		expect(view.dom.querySelectorAll(".cm-atomic-table-drop-target").length).toBe(3);
		ptr(src(2), "pointerup", { buttons: 0 });
		expect(view.dom.querySelectorAll(".cm-atomic-table-drop-target").length).toBe(0);
	});

	test("pressing a handle does not start a cell selection", () => {
		mount();
		ptr(colHandles()[0] as HTMLElement, "pointerdown");
		ptr(src(2), "pointermove");
		expect(view.dom.querySelector(".cm-atomic-table-has-selection")).toBeNull();
		ptr(src(2), "pointerup", { buttons: 0 });
	});

	test("moving with the button up cancels the drag", () => {
		mount();
		const before = view.state.doc.toString();
		ptr(colHandles()[0] as HTMLElement, "pointerdown");
		ptr(src(2), "pointermove", { buttons: 0 });
		ptr(src(2), "pointerup", { buttons: 0 });
		expect(view.state.doc.toString()).toBe(before);
	});
});
