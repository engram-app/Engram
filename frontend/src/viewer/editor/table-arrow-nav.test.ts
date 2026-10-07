import { readOnlyExtension, tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Vertical arrows used to skip a table: the block widget is atomic to the
// outer editor, so ArrowDown/ArrowUp jumped over it, and inside a cell the
// arrows did nothing useful. Patched in patches/@atomic-editor%2Feditor@*.

//        0123456 7 8...
const DOC = "before\n\n| a | b |\n| --- | --- |\n| one | two |\n\nafter\n";
const BLANK_ABOVE = DOC.indexOf("\n\n") + 1; // the empty line directly above the table
const BLANK_BELOW = DOC.indexOf("two |\n") + "two |\n".length; // empty line directly below

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc: string, anchor: number, readOnly = false): EditorView {
	view = new EditorView({
		state: EditorState.create({
			doc,
			selection: { anchor },
			extensions: [
				markdown({ base: markdownLanguage }),
				tables({}),
				...(readOnly ? [readOnlyExtension(true)] : []),
			],
		}),
		parent: document.body,
	});
	return view;
}

function cells(): HTMLElement[] {
	return Array.from(view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table-cell-source"));
}

/** Text of the table cell holding the DOM caret, or null if the caret is not in a cell. */
function caretCellText(): string | null {
	const anchor = window.getSelection()?.anchorNode;
	if (!anchor) {
		return null;
	}
	return cells().find((c) => c.contains(anchor))?.textContent ?? null;
}

function press(target: Element, key: string, init: KeyboardEventInit = {}) {
	target.dispatchEvent(
		new KeyboardEvent("keydown", { key, bubbles: true, cancelable: true, ...init }),
	);
}

function focusCell(index: number) {
	const cell = cells()[index];
	if (!cell) {
		throw new Error("no such cell");
	}
	cell.focus();
	const range = document.createRange();
	range.selectNodeContents(cell);
	range.collapse(false);
	const sel = window.getSelection();
	sel?.removeAllRanges();
	sel?.addRange(range);
	return cell;
}

describe("arrowing into a table from outside", () => {
	test("ArrowDown on the line above enters the first cell", () => {
		mount(DOC, BLANK_ABOVE);
		press(view.contentDOM, "ArrowDown");
		expect(caretCellText()).toBe("a");
	});

	test("ArrowUp on the line below enters the last row", () => {
		mount(DOC, BLANK_BELOW);
		press(view.contentDOM, "ArrowUp");
		expect(caretCellText()).toBe("one");
	});

	test("Shift+ArrowDown still extends the selection instead of entering", () => {
		mount(DOC, BLANK_ABOVE);
		press(view.contentDOM, "ArrowDown", { shiftKey: true });
		expect(caretCellText()).toBeNull();
	});

	test("a read-only table is not entered", () => {
		mount(DOC, BLANK_ABOVE, true);
		press(view.contentDOM, "ArrowDown");
		expect(caretCellText()).toBeNull();
	});

	test("ArrowDown away from the table does not enter it", () => {
		mount(DOC, 0);
		press(view.contentDOM, "ArrowDown");
		expect(caretCellText()).toBeNull();
	});
});

describe("arrowing inside a table", () => {
	test("ArrowDown moves to the cell below in the same column", () => {
		mount(DOC, BLANK_ABOVE);
		focusCell(1); // "b"
		press(cells()[1] as HTMLElement, "ArrowDown");
		expect(caretCellText()).toBe("two");
	});

	test("ArrowUp moves to the cell above in the same column", () => {
		mount(DOC, BLANK_ABOVE);
		focusCell(2); // "one"
		press(cells()[2] as HTMLElement, "ArrowUp");
		expect(caretCellText()).toBe("a");
	});

	test("ArrowDown from the last row exits to the line below the table", () => {
		mount(DOC, BLANK_ABOVE);
		const cell = focusCell(3); // "two"
		press(cell, "ArrowDown");
		expect(view.state.selection.main.head).toBe(BLANK_BELOW);
		expect(caretCellText()).toBeNull();
	});

	test("ArrowUp from the header exits to the line above the table", () => {
		mount(DOC, BLANK_BELOW);
		const cell = focusCell(0); // "a"
		press(cell, "ArrowUp");
		expect(view.state.selection.main.head).toBe(BLANK_ABOVE);
		expect(caretCellText()).toBeNull();
	});

	test("ArrowUp from a table at the very start of the doc stays put", () => {
		mount("| a |\n| --- |\n| one |\n", 0);
		const cell = focusCell(0);
		expect(() => press(cell, "ArrowUp")).not.toThrow();
		expect(caretCellText()).toBe("a");
	});

	test("ArrowDown from a table at the very end of the doc stays put", () => {
		mount("| a |\n| --- |\n| one |", 0);
		const cell = focusCell(1);
		expect(() => press(cell, "ArrowDown")).not.toThrow();
		expect(caretCellText()).toBe("one");
	});

	test("modified arrows are left to the browser", () => {
		mount(DOC, BLANK_ABOVE);
		const cell = focusCell(1);
		press(cell, "ArrowDown", { shiftKey: true });
		expect(caretCellText()).toBe("b");
	});
});
