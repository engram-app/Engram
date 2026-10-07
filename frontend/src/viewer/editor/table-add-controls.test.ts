import { readOnlyExtension, tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Hovering just off the table's right or bottom edge reveals an attached strip
// that adds a column / row (CSS shows it; these tests cover the DOM + clicks).
// Patched in patches/@atomic-editor%2Feditor@*.

const DOC = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(readOnly = false) {
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
}

const addCol = () => view.dom.querySelector<HTMLButtonElement>(".cm-atomic-table-add-col");
const addRow = () => view.dom.querySelector<HTMLButtonElement>(".cm-atomic-table-add-row");

function table(): string {
	return view.state.doc.toString().split("\n\nafter")[0] ?? "";
}

const frames = () =>
	new Promise<void>((resolve) =>
		requestAnimationFrame(() => requestAnimationFrame(() => resolve())),
	);

describe("add column / add row strips", () => {
	test("an editable table gets both strips, labelled", () => {
		mount();
		expect(addCol()?.getAttribute("aria-label")).toBe("Add column");
		expect(addRow()?.getAttribute("aria-label")).toBe("Add row");
	});

	test("they are plain buttons, not submit buttons", () => {
		mount();
		expect(addCol()?.type).toBe("button");
		expect(addRow()?.type).toBe("button");
	});

	test("a read-only table gets neither", () => {
		mount(true);
		expect(addCol()).toBeNull();
		expect(addRow()).toBeNull();
	});

	test("they sit outside the <table>, so cell indexing is unchanged", () => {
		mount();
		const tableEl = view.dom.querySelector("table");
		expect(tableEl?.contains(addCol() as Node)).toBe(false);
		expect(tableEl?.contains(addRow() as Node)).toBe(false);
		expect(view.dom.querySelectorAll(".cm-atomic-table th, .cm-atomic-table td")).toHaveLength(9);
	});

	test("clicking the row strip appends an empty row", () => {
		mount();
		addRow()?.click();
		expect(table()).toBe(
			"| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n|  |  |  |",
		);
	});

	test("clicking the column strip appends an empty column", () => {
		mount();
		addCol()?.click();
		expect(table()).toBe(
			"| a | b | c |  |\n| --- | --- | --- | --- |\n| 1 | 2 | 3 |  |\n| 4 | 5 | 6 |  |",
		);
	});

	test("the new column's header cell takes the caret", async () => {
		mount();
		addCol()?.click();
		await frames();
		const headers = view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table thead th");
		expect(headers).toHaveLength(4);
		const anchor = window.getSelection()?.anchorNode;
		expect(anchor && headers[3]?.contains(anchor)).toBe(true);
	});

	test("the strips survive a rebuild (they are re-created with the widget)", () => {
		mount();
		addRow()?.click();
		expect(addCol()).not.toBeNull();
		expect(addRow()).not.toBeNull();
	});

	test("clicking a strip does not start a cell selection", () => {
		mount();
		addRow()?.dispatchEvent(
			new MouseEvent("pointerdown", { bubbles: true, button: 0, buttons: 1 }),
		);
		expect(view.dom.querySelector(".cm-atomic-table-has-selection")).toBeNull();
	});
});
