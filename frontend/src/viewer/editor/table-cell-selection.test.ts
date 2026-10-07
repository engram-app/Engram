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
