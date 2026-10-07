import { tables } from "@atomic-editor/editor";
import { history, historyKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState, type Extension } from "@codemirror/state";
import { EditorView, keymap } from "@codemirror/view";
import { afterEach, describe, expect, test, vi } from "vitest";

// Table edits must be undoable. A table is a widget the editor's keymap never
// sees key events from, so Ctrl/Cmd+Z pressed in (or next to) it did nothing;
// and the widget kept its old DOM across a same-shape document change, so even
// an undo that did run left the cells showing stale text.
// Patched in patches/@atomic-editor%2Feditor@*.
//
//   idx:  0 1 2      a | b | c
//         3 4 5      1 | 2 | 3
//         6 7 8      4 | 5 | 6
const DOC = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(extra: Extension[] = []) {
	view = new EditorView({
		state: EditorState.create({
			doc: DOC,
			extensions: [markdown({ base: markdownLanguage }), tables({}), ...extra],
		}),
		parent: document.body,
	});
}

const withHistory = () => [history(), keymap.of(historyKeymap)];
const table = () => view.state.doc.toString().split("\n\nafter")[0] ?? "";
const cells = () =>
	Array.from(view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table th, .cm-atomic-table td"));
const src = (i: number) => cells()[i]?.querySelector(".cm-atomic-table-cell-source") as HTMLElement;
const wrap = () => view.dom.querySelector(".cm-atomic-table") as HTMLElement;

function key(target: Element, k: string, init: KeyboardEventInit = {}) {
	const ev = new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true, ...init });
	target.dispatchEvent(ev);
	return ev;
}

/** Type `text` at the end of cell `i` the way the browser would. */
function typeIn(i: number, text: string) {
	const source = src(i);
	source.textContent = `${source.textContent}${text}`;
	const range = document.createRange();
	range.selectNodeContents(source);
	range.collapse(false);
	window.getSelection()?.removeAllRanges();
	window.getSelection()?.addRange(range);
	source.dispatchEvent(new Event("input", { bubbles: true }));
}

function selectBox(from: number, to: number) {
	const ptr = (el: Element, type: string, buttons: number) =>
		el.dispatchEvent(new MouseEvent(type, { bubbles: true, cancelable: true, button: 0, buttons }));
	ptr(src(from), "pointerdown", 1);
	ptr(src(to), "pointermove", 1);
	ptr(src(to), "pointerup", 0);
}

describe("undo / redo keys reach the editor from inside a table", () => {
	test("Ctrl+Z in a cell runs the editor's undo binding", () => {
		const undo = vi.fn(() => true);
		mount([keymap.of([{ key: "Mod-z", run: undo }])]);
		const ev = key(src(4), "z", { ctrlKey: true });
		expect(undo).toHaveBeenCalledTimes(1);
		expect(ev.defaultPrevented).toBe(true);
	});

	test("Ctrl+Shift+Z and Ctrl+Y run redo", () => {
		const redoA = vi.fn(() => true);
		const redoB = vi.fn(() => true);
		mount([
			keymap.of([
				{ key: "Mod-Shift-z", run: redoA },
				{ key: "Mod-y", run: redoB },
			]),
		]);
		key(src(4), "z", { ctrlKey: true, shiftKey: true });
		key(src(4), "y", { ctrlKey: true });
		expect(redoA).toHaveBeenCalledTimes(1);
		expect(redoB).toHaveBeenCalledTimes(1);
	});

	test("it also works from the table itself (after a box selection)", () => {
		const undo = vi.fn(() => true);
		mount([keymap.of([{ key: "Mod-z", run: undo }])]);
		key(wrap(), "z", { ctrlKey: true });
		expect(undo).toHaveBeenCalledTimes(1);
	});

	test("a key the editor does not handle is left to the browser", () => {
		mount();
		expect(key(src(4), "z", { ctrlKey: true }).defaultPrevented).toBe(false);
	});

	test("other Ctrl shortcuts are untouched", () => {
		const undo = vi.fn(() => true);
		mount([keymap.of([{ key: "Mod-z", run: undo }])]);
		key(src(4), "b", { ctrlKey: true });
		key(src(4), "z", {});
		expect(undo).not.toHaveBeenCalled();
	});
});

describe("undoing table edits", () => {
	test("deleting a row can be undone, and the table shows it", () => {
		mount(withHistory());
		selectBox(3, 5);
		key(wrap(), "Backspace");
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |");
		key(wrap(), "z", { ctrlKey: true });
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |");
		expect(view.dom.querySelectorAll(".cm-atomic-table tbody tr")).toHaveLength(2);
	});

	test("clearing cells can be undone and the cells show the restored text", () => {
		mount(withHistory());
		selectBox(3, 4);
		key(wrap(), "Backspace");
		expect(src(3).textContent).toBe("");
		key(wrap(), "z", { ctrlKey: true });
		expect(table()).toContain("| 1 | 2 | 3 |");
		expect(src(3).textContent).toBe("1");
		expect(src(4).textContent).toBe("2");
	});

	test("a column move can be undone", () => {
		mount(withHistory());
		const handle = view.dom.querySelector(".cm-atomic-table-handle-col") as HTMLElement;
		handle.dispatchEvent(new MouseEvent("pointerdown", { bubbles: true, button: 0, buttons: 1 }));
		src(2).dispatchEvent(new MouseEvent("pointermove", { bubbles: true, buttons: 1 }));
		src(2).dispatchEvent(new MouseEvent("pointerup", { bubbles: true, buttons: 0 }));
		expect(table().startsWith("| b | c | a |")).toBe(true);
		key(wrap(), "z", { ctrlKey: true });
		expect(table().startsWith("| a | b | c |")).toBe(true);
		expect(src(0).textContent).toBe("a");
	});

	test("typing in a cell can be undone and the cell shows the old text", () => {
		mount(withHistory());
		typeIn(4, "x");
		expect(table()).toContain("| 1 | 2x | 3 |");
		key(src(4), "z", { ctrlKey: true });
		expect(table()).toContain("| 1 | 2 | 3 |");
		expect(src(4).textContent).toBe("2");
	});
});

describe("the widget keeps its DOM while you type, but refreshes on other changes", () => {
	test("typing does not rebuild the table", () => {
		mount();
		const before = cells()[4];
		typeIn(4, "x");
		expect(cells()[4]).toBe(before);
	});

	test("typing a pipe or a trailing space does not rebuild the table either", () => {
		mount();
		const before = cells()[4];
		typeIn(4, "|");
		typeIn(4, " ");
		expect(cells()[4]).toBe(before);
	});

	test("a same-shape change from elsewhere (remote edit, undo) updates the cells", () => {
		mount();
		const from = view.state.doc.toString().indexOf("| 1 | 2 | 3 |") + 2;
		view.dispatch({ changes: { from, to: from + 1, insert: "ONE" } });
		expect(src(3).textContent).toBe("ONE");
	});
});
