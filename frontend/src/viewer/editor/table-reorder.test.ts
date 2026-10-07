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
	test("each column and each row, header included, gets one", () => {
		mount();
		expect(colHandles()).toHaveLength(3);
		expect(rowHandles()).toHaveLength(3);
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
			0, 3, 6,
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
			0, 3, 6,
		]);
	});
});

describe("dragging a row handle", () => {
	test("onto a row below moves the row there", () => {
		mount();
		dragHandle(rowHandles()[1], 6);
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("onto a row above moves the row there", () => {
		mount();
		dragHandle(rowHandles()[2], 3);
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("dropping a body row on the header row makes it the header", () => {
		mount();
		dragHandle(rowHandles()[1], 1); // first body row onto a header cell
		expect(table()).toBe("| 1 | 2 | 3 |\n| --- | --- | --- |\n| a | b | c |\n| 4 | 5 | 6 |");
	});

	test("the header row can be dragged down into the body", () => {
		mount();
		dragHandle(rowHandles()[0], 6); // header onto the last row
		expect(table()).toBe("| 1 | 2 | 3 |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| a | b | c |");
	});

	test("dropping on its own row changes nothing", () => {
		mount();
		const before = view.state.doc.toString();
		dragHandle(rowHandles()[1], 4);
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

describe("handle visibility while dragging", () => {
	const wrap = () => view.dom.querySelector(".cm-atomic-table");

	test("the dragged handle and the table are marked until the drop", () => {
		mount();
		const handle = colHandles()[0] as HTMLElement;
		expect(handle.classList.contains("cm-atomic-table-handle-dragging")).toBe(false);
		ptr(handle, "pointerdown");
		expect(handle.classList.contains("cm-atomic-table-handle-dragging")).toBe(true);
		expect(wrap()?.classList.contains("cm-atomic-table-dragging")).toBe(true);
		ptr(src(2), "pointermove");
		expect(handle.classList.contains("cm-atomic-table-handle-dragging")).toBe(true);
		ptr(src(2), "pointerup", { buttons: 0 });
		expect(view.dom.querySelector(".cm-atomic-table-handle-dragging")).toBeNull();
		expect(wrap()?.classList.contains("cm-atomic-table-dragging")).toBe(false);
	});

	test("a drag that ends with the button already up clears the marks", () => {
		mount();
		ptr(rowHandles()[0] as HTMLElement, "pointerdown");
		ptr(src(4), "pointermove", { buttons: 0 });
		expect(view.dom.querySelector(".cm-atomic-table-handle-dragging")).toBeNull();
		expect(wrap()?.classList.contains("cm-atomic-table-dragging")).toBe(false);
	});

	test("the mark stays on the dragged handle even when the pointer leaves the table", () => {
		mount();
		const handle = rowHandles()[0] as HTMLElement;
		ptr(handle, "pointerdown");
		ptr(document.body, "pointermove");
		expect(handle.classList.contains("cm-atomic-table-handle-dragging")).toBe(true);
		ptr(document.body, "pointerup", { buttons: 0 });
	});
});

describe("the handle slides with the pointer", () => {
	/** happy-dom has no layout; give the table a 3 x 3 grid of 100 x 40 cells at (100, 100). */
	function fakeLayout() {
		const rect = (left: number, top: number, w: number, h: number) =>
			({
				left,
				top,
				right: left + w,
				bottom: top + h,
				width: w,
				height: h,
				x: left,
				y: top,
			}) as DOMRect;
		const at = (el: Element | null | undefined, r: DOMRect) => {
			if (el) {
				el.getBoundingClientRect = () => r;
			}
		};
		const root = view.dom.querySelector(".cm-atomic-table");
		at(root?.querySelector("table"), rect(100, 100, 300, 120));
		view.dom.querySelectorAll(".cm-atomic-table thead th").forEach((th, i) => {
			at(th, rect(100 + i * 100, 100, 100, 40));
		});
		view.dom.querySelectorAll(".cm-atomic-table tr").forEach((tr, i) => {
			at(tr, rect(100, 100 + i * 40, 300, 40));
		});
		colHandles().forEach((h, i) => {
			at(h, rect(100 + i * 100, 86, 100, 11));
		});
		rowHandles().forEach((h, i) => {
			at(h, rect(86, 100 + i * 40, 11, 40));
		});
	}

	test("a column handle follows the pointer horizontally, unsnapped", () => {
		mount();
		fakeLayout();
		const handle = colHandles()[0] as HTMLElement;
		ptr(handle, "pointerdown", { clientX: 150, clientY: 90 });
		ptr(document.body, "pointermove", { clientX: 187, clientY: 400 }); // y is irrelevant on a column rail
		expect(handle.style.transform).toBe("translateX(37px)");
		ptr(document.body, "pointerup", { buttons: 0 });
	});

	test("a row handle follows the pointer vertically", () => {
		mount();
		fakeLayout();
		const handle = rowHandles()[0] as HTMLElement;
		ptr(handle, "pointerdown", { clientX: 90, clientY: 160 });
		ptr(document.body, "pointermove", { clientX: 300, clientY: 173 });
		expect(handle.style.transform).toBe("translateY(13px)");
		ptr(document.body, "pointerup", { buttons: 0 });
	});

	test("it stays on its rail: clamped to the table's extent", () => {
		mount();
		fakeLayout();
		const handle = colHandles()[0] as HTMLElement; // spans x 100..200, table ends at 400
		ptr(handle, "pointerdown", { clientX: 150 });
		ptr(document.body, "pointermove", { clientX: 5000 });
		expect(handle.style.transform).toBe("translateX(200px)");
		ptr(document.body, "pointermove", { clientX: -5000 });
		expect(handle.style.transform).toBe("translateX(0px)");
		ptr(document.body, "pointerup", { buttons: 0 });
	});

	test("a row handle is clamped to the table's rows", () => {
		mount();
		fakeLayout();
		const handle = rowHandles()[1] as HTMLElement; // first body row, y 140..180; table spans 100..220
		ptr(handle, "pointerdown", { clientY: 160 });
		ptr(document.body, "pointermove", { clientY: -5000 });
		expect(handle.style.transform).toBe("translateY(-40px)");
		ptr(document.body, "pointermove", { clientY: 5000 });
		expect(handle.style.transform).toBe("translateY(40px)");
		ptr(document.body, "pointerup", { buttons: 0 });
	});

	test("the landing slot follows the pointer's position, even outside the table", () => {
		mount();
		fakeLayout();
		ptr(colHandles()[0] as HTMLElement, "pointerdown", { clientX: 150 });
		ptr(document.body, "pointermove", { clientX: 350, clientY: 20 }); // over column 2, above the table
		const marked = Array.from(
			view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table-drop-target"),
		);
		expect(marked).toHaveLength(3);
		expect(marked.every((c) => cells().indexOf(c) % 3 === 2)).toBe(true);
		ptr(document.body, "pointerup", { buttons: 0 });
		expect(table()).toBe("| b | c | a |\n| --- | --- | --- |\n| 2 | 3 | 1 |\n| 5 | 6 | 4 |");
	});

	test("a row drops where the pointer is vertically", () => {
		mount();
		fakeLayout();
		ptr(rowHandles()[1] as HTMLElement, "pointerdown", { clientY: 160 });
		ptr(document.body, "pointermove", { clientX: 5, clientY: 205 }); // over the second body row
		ptr(document.body, "pointerup", { buttons: 0 });
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("the offset is cleared when the drag ends", () => {
		mount();
		fakeLayout();
		const handle = colHandles()[1] as HTMLElement;
		ptr(handle, "pointerdown", { clientX: 250 });
		ptr(document.body, "pointermove", { clientX: 260 });
		ptr(document.body, "pointerup", { buttons: 0 });
		expect(handle.style.transform).toBe("");
	});
});
