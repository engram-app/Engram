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

function mount(readOnly = false, doc = DOC): HTMLElement[] {
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

describe("copy / cut / paste on a cell selection", () => {
	const HEADER = "| a | b | c |\n| --- | --- | --- |\n";

	/** Fire a clipboard event on the table with an in-memory clipboard. */
	function clip(type: "copy" | "cut" | "paste", preload: Record<string, string> = {}) {
		const store: Record<string, string> = { ...preload };
		const ev = new Event(type, { bubbles: true, cancelable: true });
		Object.defineProperty(ev, "clipboardData", {
			value: {
				setData: (t: string, v: string) => {
					store[t] = v;
				},
				getData: (t: string) => store[t] ?? "",
			},
		});
		view.dom.querySelector(".cm-atomic-table")?.dispatchEvent(ev);
		return { ev, store };
	}

	const paste = (text: string) => clip("paste", { "text/plain": text });

	/** The table's markdown, without the trailing "after" paragraph. */
	function table(): string {
		return view.state.doc.toString().split("\n\nafter")[0] ?? "";
	}

	test("copy puts the box on the clipboard as tab-separated text", () => {
		mount();
		drag(3, 8);
		const { ev, store } = clip("copy");
		expect(store["text/plain"]).toBe("1\t2\t3\n4\t5\t6");
		expect(ev.defaultPrevented).toBe(true);
	});

	test("copy takes only the selected box", () => {
		mount();
		drag(1, 8);
		expect(clip("copy").store["text/plain"]).toBe("b\tc\n2\t3\n5\t6");
	});

	test("copy also offers an HTML table, escaped", () => {
		mount(false, "| a | b |\n| --- | --- |\n| x<y | 2 |\n");
		drag(0, 3);
		const html = clip("copy").store["text/html"] ?? "";
		expect(html).toContain("<td>x&lt;y</td>");
		expect(html).toContain("<td>2</td>");
	});

	test("copy with no selection is left to the browser", () => {
		mount();
		const { ev, store } = clip("copy");
		expect(ev.defaultPrevented).toBe(false);
		expect(store["text/plain"]).toBeUndefined();
	});

	test("copy works on a read-only table", () => {
		mount(true);
		drag(3, 5);
		expect(clip("copy").store["text/plain"]).toBe("1\t2\t3");
	});

	test("cut copies, then clears the contents", () => {
		mount();
		drag(3, 4);
		expect(clip("cut").store["text/plain"]).toBe("1\t2");
		expect(table()).toBe(`${HEADER}|  |  | 3 |\n| 4 | 5 | 6 |`);
	});

	test("cut never removes a row, even a fully selected one", () => {
		mount();
		drag(3, 5);
		clip("cut");
		expect(table()).toBe(`${HEADER}|  |  |  |\n| 4 | 5 | 6 |`);
	});

	test("cut on a read-only table copies but does not edit", () => {
		mount(true);
		const before = view.state.doc.toString();
		drag(3, 5);
		expect(clip("cut").store["text/plain"]).toBe("1\t2\t3");
		expect(view.state.doc.toString()).toBe(before);
	});

	test("paste fills the grid from the top-left of the selection", () => {
		mount();
		drag(4, 5);
		paste("x\ty\nz\tw");
		expect(table()).toBe(`${HEADER}| 1 | x | y |\n| 4 | z | w |`);
	});

	test("paste clips columns that would fall off the right edge", () => {
		mount();
		drag(4, 5);
		paste("p\tq\tr");
		expect(table()).toBe(`${HEADER}| 1 | p | q |\n| 4 | 5 | 6 |`);
	});

	test("paste grows the table by rows when the clipboard is taller", () => {
		mount();
		drag(6, 7);
		paste("a\nb\nc");
		expect(table()).toBe(`${HEADER}| 1 | 2 | 3 |\n| a | 5 | 6 |\n| b |  |  |\n| c |  |  |`);
	});

	test("a single pasted value fills every selected cell", () => {
		mount();
		drag(3, 8);
		paste("X");
		expect(table()).toBe(`${HEADER}| X | X | X |\n| X | X | X |`);
	});

	test("paste accepts CRLF and ignores one trailing newline", () => {
		mount();
		drag(3, 6);
		paste("x\r\ny\r\n");
		expect(table()).toBe(`${HEADER}| x | 2 | 3 |\n| y | 5 | 6 |`);
	});

	test("the pasted block becomes the selection", () => {
		mount();
		drag(4, 5);
		paste("x\ty\nz\tw");
		expect(selected()).toEqual([4, 5, 7, 8]);
	});

	test("a pasted pipe is escaped so it cannot split the cell", () => {
		mount();
		drag(3, 4);
		paste("a|b\tc");
		expect(table()).toContain("| a\\|b | c | 3 |");
	});

	test("paste with no selection is left to the browser", () => {
		mount();
		const { ev } = paste("x");
		expect(ev.defaultPrevented).toBe(false);
	});

	test("paste into a read-only table does nothing", () => {
		mount(true);
		const before = view.state.doc.toString();
		drag(3, 5);
		paste("x");
		expect(view.state.doc.toString()).toBe(before);
	});

	test("paste with an empty clipboard does nothing", () => {
		mount();
		const before = view.state.doc.toString();
		drag(3, 5);
		paste("");
		expect(view.state.doc.toString()).toBe(before);
	});
});

describe("extending a selection", () => {
	function shiftClick(i: number, init: MouseEventInit = {}) {
		return ptr(src(i), "pointerdown", { shiftKey: true, ...init });
	}

	function arrow(key: string, init: KeyboardEventInit = {}) {
		const wrap = view.dom.querySelector(".cm-atomic-table");
		const ev = new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init });
		wrap?.dispatchEvent(ev);
		return ev;
	}

	function caretIn(i: number) {
		const cell = src(i);
		const range = document.createRange();
		range.selectNodeContents(cell);
		range.collapse(false);
		const sel = window.getSelection();
		sel?.removeAllRanges();
		sel?.addRange(range);
	}

	test("Shift-click extends the box from its anchor", () => {
		mount();
		drag(0, 4);
		shiftClick(8);
		expect(selected()).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8]);
	});

	test("Shift-click keeps the original anchor across several clicks", () => {
		mount();
		drag(0, 4);
		shiftClick(8);
		shiftClick(2);
		expect(selected()).toEqual([0, 1, 2]);
	});

	test("Shift-click from a cell with the caret in it starts a box there", () => {
		mount();
		caretIn(4);
		shiftClick(8);
		expect(selected()).toEqual([4, 5, 7, 8]);
	});

	test("Shift-click with no selection and no caret in the table does nothing", () => {
		mount();
		window.getSelection()?.removeAllRanges();
		shiftClick(8);
		expect(selected()).toEqual([]);
	});

	test("Shift-click suppresses the native text range", () => {
		mount();
		drag(0, 4);
		expect(shiftClick(8).defaultPrevented).toBe(true);
	});

	test("Shift-click works in a read-only table", () => {
		mount(true);
		drag(0, 4);
		shiftClick(8);
		expect(selected()).toEqual([0, 1, 2, 3, 4, 5, 6, 7, 8]);
	});

	test("Shift+Arrow moves the free corner one cell", () => {
		mount();
		drag(3, 4);
		arrow("ArrowRight", { shiftKey: true });
		expect(selected()).toEqual([3, 4, 5]);
		arrow("ArrowDown", { shiftKey: true });
		expect(selected()).toEqual([3, 4, 5, 6, 7, 8]);
		arrow("ArrowLeft", { shiftKey: true });
		expect(selected()).toEqual([3, 4, 6, 7]);
		arrow("ArrowUp", { shiftKey: true });
		expect(selected()).toEqual([3, 4]);
	});

	test("Shift+Arrow stops at the table edge", () => {
		mount();
		drag(1, 2);
		arrow("ArrowRight", { shiftKey: true });
		arrow("ArrowUp", { shiftKey: true });
		expect(selected()).toEqual([1, 2]);
	});

	test("Ctrl+Shift+Arrow extends to the edge", () => {
		mount();
		drag(0, 1);
		arrow("ArrowDown", { shiftKey: true, ctrlKey: true });
		expect(selected()).toEqual([0, 1, 3, 4, 6, 7]);
	});

	test("Cmd+Shift+Arrow extends to the edge too", () => {
		mount();
		drag(0, 3);
		arrow("ArrowRight", { shiftKey: true, metaKey: true });
		expect(selected()).toEqual([0, 1, 2, 3, 4, 5]);
	});

	test("Shift+Arrow is consumed so the caret and page do not move", () => {
		mount();
		drag(3, 4);
		expect(arrow("ArrowRight", { shiftKey: true }).defaultPrevented).toBe(true);
	});

	test("Shift+Arrow with no selection is left alone", () => {
		mount();
		expect(arrow("ArrowRight", { shiftKey: true }).defaultPrevented).toBe(false);
		expect(selected()).toEqual([]);
	});

	test("Shift+Arrow works in a read-only table", () => {
		mount(true);
		drag(3, 4);
		arrow("ArrowRight", { shiftKey: true });
		expect(selected()).toEqual([3, 4, 5]);
	});
});

describe("pasting a grid with the caret in a cell", () => {
	const HEADER = "| a | b | c |\n| --- | --- | --- |\n";

	function pasteInCell(i: number, text: string, html = "") {
		const store: Record<string, string> = { "text/plain": text, "text/html": html };
		const ev = new Event("paste", { bubbles: true, cancelable: true });
		Object.defineProperty(ev, "clipboardData", {
			value: { setData: () => {}, getData: (t: string) => store[t] ?? "" },
		});
		const cell = src(i);
		const range = document.createRange();
		range.selectNodeContents(cell);
		range.collapse(false);
		window.getSelection()?.removeAllRanges();
		window.getSelection()?.addRange(range);
		cell.dispatchEvent(ev);
		return ev;
	}

	function table(): string {
		return view.state.doc.toString().split("\n\nafter")[0] ?? "";
	}

	test("tab-separated text spreads across cells from the caret cell", () => {
		mount();
		pasteInCell(4, "x\ty\nz\tw");
		expect(table()).toBe(`${HEADER}| 1 | x | y |\n| 4 | z | w |`);
	});

	test("a copied table column (HTML table, no tabs) pastes as rows", () => {
		mount();
		pasteInCell(3, "p\nq", "<table><tr><td>p</td></tr><tr><td>q</td></tr></table>");
		expect(table()).toBe(`${HEADER}| p | 2 | 3 |\n| q | 5 | 6 |`);
	});

	test("plain multi-line text without tabs is still flattened into the one cell", () => {
		mount();
		pasteInCell(3, "hello\nworld");
		expect(table()).toBe(`${HEADER}| 1hello world | 2 | 3 |\n| 4 | 5 | 6 |`);
	});

	test("a grid paste does not leave a stale box selection", () => {
		mount();
		pasteInCell(4, "x\ty\nz\tw");
		expect(selected()).toEqual([]);
	});
});
