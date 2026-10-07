import { readOnlyExtension, tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Click-drag across table cells selects a rectangle of cells ("box mode"),
// highlighted until Esc / a click elsewhere. Patched in
// patches/@atomic-editor%2Feditor@*.
//
//   idx:  0 1 2      a | b | c
//         3 4 5      1 | 2 | 3
//         6 7 8      4 | 5 | 6
const DOC = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n";
const SELECTED = "cm-atomic-table-cell-selected";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(readOnly = false): HTMLElement[] {
	view = new EditorView({
		state: EditorState.create({
			doc: DOC,
			extensions: [
				markdown({ base: markdownLanguage }),
				tables({}),
				...(readOnly ? [readOnlyExtension(true)] : []),
			],
		}),
		parent: document.body,
	});
	return cells();
}

function cells(): HTMLElement[] {
	return Array.from(
		view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table th, .cm-atomic-table td"),
	);
}

function selected(): number[] {
	return cells().flatMap((c, i) => (c.classList.contains(SELECTED) ? [i] : []));
}

/** Indexes of cells carrying the outline edge `side` (top|right|bottom|left). */
function edge(side: string): number[] {
	return cells().flatMap((c, i) =>
		c.classList.contains(`cm-atomic-table-cell-sel-${side}`) ? [i] : [],
	);
}

function ptr(target: Element, type: string, init: MouseEventInit = {}) {
	const Ctor = typeof PointerEvent === "undefined" ? MouseEvent : PointerEvent;
	const ev = new Ctor(type, { bubbles: true, cancelable: true, button: 0, buttons: 1, ...init });
	target.dispatchEvent(ev);
	return ev;
}

function src(i: number): HTMLElement {
	const el = cells()[i]?.querySelector<HTMLElement>(".cm-atomic-table-cell-source");
	if (!el) {
		throw new Error(`no cell ${i}`);
	}
	return el;
}

/** Press in cell `from`, drag over each of `via`, release over the last. */
function drag(from: number, ...via: number[]) {
	ptr(src(from), "pointerdown");
	for (const i of via) {
		ptr(src(i), "pointermove");
	}
	ptr(src(via.at(-1) ?? from), "pointerup", { buttons: 0 });
}

describe("drag-selecting table cells", () => {
	test("dragging to another cell selects the rectangle between them", () => {
		mount();
		drag(3, 8);
		expect(selected()).toEqual([3, 4, 5, 6, 7, 8]);
	});

	test("the rectangle is a box, not a run of cells in reading order", () => {
		mount();
		drag(1, 8);
		expect(selected()).toEqual([1, 2, 4, 5, 7, 8]);
	});

	test("dragging up and left selects the same box", () => {
		mount();
		drag(8, 1);
		expect(selected()).toEqual([1, 2, 4, 5, 7, 8]);
	});

	test("the box follows the pointer as it moves", () => {
		mount();
		drag(0, 4, 2);
		expect(selected()).toEqual([0, 1, 2]);
	});

	test("dragging within a single cell does not select cells", () => {
		mount();
		drag(4, 4);
		expect(selected()).toEqual([]);
	});

	test("moving over cells without the button down selects nothing", () => {
		mount();
		ptr(src(0), "pointermove", { buttons: 0 });
		ptr(src(8), "pointermove", { buttons: 0 });
		expect(selected()).toEqual([]);
	});

	test("the selection stays put when the pointer moves after release", () => {
		mount();
		drag(0, 4);
		ptr(src(8), "pointermove", { buttons: 0 });
		expect(selected()).toEqual([0, 1, 3, 4]);
	});

	test("the table is flagged while it holds a selection", () => {
		mount();
		const wrap = view.dom.querySelector(".cm-atomic-table");
		expect(wrap?.classList.contains("cm-atomic-table-has-selection")).toBe(false);
		drag(0, 4);
		expect(wrap?.classList.contains("cm-atomic-table-has-selection")).toBe(true);
	});

	test("native text selection is suppressed while the box is dragged", () => {
		mount();
		ptr(src(0), "pointerdown");
		ptr(src(4), "pointermove");
		const ev = new Event("selectstart", { bubbles: true, cancelable: true });
		src(4).dispatchEvent(ev);
		expect(ev.defaultPrevented).toBe(true);
	});

	test("works in a read-only table too", () => {
		mount(true);
		drag(3, 8);
		expect(selected()).toEqual([3, 4, 5, 6, 7, 8]);
	});
});

describe("clearing a cell selection", () => {
	test("Escape clears it", () => {
		mount();
		drag(0, 4);
		document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
		expect(selected()).toEqual([]);
		expect(view.dom.querySelector(".cm-atomic-table-has-selection")).toBeNull();
	});

	test("pressing outside the table clears it", () => {
		mount();
		drag(0, 4);
		ptr(view.contentDOM, "pointerdown");
		expect(selected()).toEqual([]);
	});

	test("a plain click in a cell clears it", () => {
		mount();
		drag(0, 4);
		ptr(src(8), "pointerdown");
		ptr(src(8), "pointerup", { buttons: 0 });
		expect(selected()).toEqual([]);
	});

	test("typing in a cell clears it", () => {
		mount();
		drag(0, 4);
		src(8).dispatchEvent(new Event("input", { bubbles: true }));
		expect(selected()).toEqual([]);
	});

	test("starting a new drag replaces the old selection", () => {
		mount();
		drag(0, 4);
		drag(5, 8);
		expect(selected()).toEqual([5, 8]);
	});
});

describe("the selection outline", () => {
	test("only the cells on the box boundary carry an edge", () => {
		mount();
		drag(1, 8); // cols 1-2, rows 0-2
		expect(edge("top")).toEqual([1, 2]);
		expect(edge("bottom")).toEqual([7, 8]);
		expect(edge("left")).toEqual([1, 4, 7]);
		expect(edge("right")).toEqual([2, 5, 8]);
	});

	test("an inner cell carries no edge", () => {
		mount();
		drag(0, 8); // the whole table; cell 4 is interior
		const inner = cells()[4];
		expect(inner?.classList.contains(SELECTED)).toBe(true);
		for (const side of ["top", "right", "bottom", "left"]) {
			expect(inner?.classList.contains(`cm-atomic-table-cell-sel-${side}`)).toBe(false);
		}
	});

	test("shrinking the box drops the edges it left behind", () => {
		mount();
		drag(0, 8, 1); // out to the far corner, back to the next cell
		expect(selected()).toEqual([0, 1]);
		expect(edge("bottom")).toEqual([0, 1]);
		expect(edge("right")).toEqual([1]);
	});

	test("clearing removes the edges", () => {
		mount();
		drag(0, 4);
		document.dispatchEvent(new KeyboardEvent("keydown", { key: "Escape", bubbles: true }));
		expect([...edge("top"), ...edge("right"), ...edge("bottom"), ...edge("left")]).toEqual([]);
	});
});

describe("Backspace / Delete on a cell selection", () => {
	const HEADER = "| a | b | c |\n| --- | --- | --- |\n";

	function press(key: string) {
		const wrap = view.dom.querySelector(".cm-atomic-table");
		wrap?.dispatchEvent(new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true }));
	}

	/** The table's markdown, without the trailing "after" paragraph. */
	function table(): string {
		return view.state.doc.toString().split("\n\nafter")[0] ?? "";
	}

	test("a fully selected row is removed", () => {
		mount();
		drag(3, 5);
		press("Backspace");
		expect(table()).toBe(`${HEADER}| 4 | 5 | 6 |`);
	});

	test("Delete removes it too", () => {
		mount();
		drag(3, 5);
		press("Delete");
		expect(table()).toBe(`${HEADER}| 4 | 5 | 6 |`);
	});

	test("several fully selected rows are removed together", () => {
		mount();
		drag(3, 8);
		press("Backspace");
		expect(table()).toBe(HEADER.trimEnd());
	});

	test("a fully selected column is removed", () => {
		mount();
		drag(1, 7);
		press("Backspace");
		expect(table()).toBe("| a | c |\n| --- | --- |\n| 1 | 3 |\n| 4 | 6 |");
	});

	test("several fully selected columns are removed together", () => {
		mount();
		drag(0, 7);
		press("Backspace");
		expect(table()).toBe("| c |\n| --- |\n| 3 |\n| 6 |");
	});

	test("a partial selection only clears the content", () => {
		mount();
		drag(3, 4);
		press("Backspace");
		expect(table()).toBe(`${HEADER}|  |  | 3 |\n| 4 | 5 | 6 |`);
		expect(cells()[3]?.textContent).toBe("");
		expect(cells()[4]?.textContent).toBe("");
	});

	test("the whole table selected clears the content and keeps the structure", () => {
		mount();
		drag(0, 8);
		press("Backspace");
		expect(table()).toBe("|  |  |  |\n| --- | --- | --- |\n|  |  |  |\n|  |  |  |");
	});

	test("a selection that includes the header clears it (it can't be removed) and drops the body rows", () => {
		mount();
		drag(0, 5);
		press("Backspace");
		expect(table()).toBe("|  |  |  |\n| --- | --- | --- |\n| 4 | 5 | 6 |");
	});

	test("the outline is gone once a row is removed", () => {
		mount();
		drag(3, 5);
		press("Backspace");
		expect(view.dom.querySelector(".cm-atomic-table-has-selection")).toBeNull();
	});

	test("with no selection it does nothing", () => {
		mount();
		const before = view.state.doc.toString();
		press("Backspace");
		expect(view.state.doc.toString()).toBe(before);
	});

	test("a read-only table is never edited", () => {
		mount(true);
		const before = view.state.doc.toString();
		drag(3, 5);
		press("Backspace");
		expect(view.state.doc.toString()).toBe(before);
	});
});
