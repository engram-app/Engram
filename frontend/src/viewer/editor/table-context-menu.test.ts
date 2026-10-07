import { tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Right-click menu: move row / column, sort by column, set alignment (plus the
// existing insert / delete). Patched in patches/@atomic-editor%2Feditor@*.
//
//   idx:  0 1 2      a | b | c
//         3 4 5      1 | 2 | 3
//         6 7 8      4 | 5 | 6
const DOC = "| a | b | c |\n| --- | --- | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |\n\nafter\n";
const SORTABLE = "| n | v |\n| --- | --- |\n| x | 10 |\n| y | 2 |\n| z | 33 |\n\nafter\n";

let view: EditorView;
afterEach(() => {
	view?.destroy();
	for (const m of document.querySelectorAll(".cm-atomic-table-menu")) {
		m.remove();
	}
});

function mount(doc = DOC) {
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [markdown({ base: markdownLanguage }), tables({})],
		}),
		parent: document.body,
	});
}

const table = () => view.state.doc.toString().split("\n\nafter")[0] ?? "";
const cells = () =>
	Array.from(view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table th, .cm-atomic-table td"));

function openMenu(i: number) {
	const target = cells()[i]?.querySelector(".cm-atomic-table-cell-source");
	target?.dispatchEvent(
		new MouseEvent("contextmenu", { bubbles: true, cancelable: true, clientX: 5, clientY: 5 }),
	);
}

function item(label: string): HTMLButtonElement | undefined {
	return Array.from(
		document.querySelectorAll<HTMLButtonElement>(".cm-atomic-table-menu-item"),
	).find((b) => b.textContent === label);
}

function choose(i: number, label: string) {
	openMenu(i);
	const btn = item(label);
	if (!btn) {
		throw new Error(`no menu item "${label}"`);
	}
	btn.click();
}

describe("menu contents", () => {
	test("a header cell offers column actions, sorting and alignment but no row actions", () => {
		mount();
		openMenu(1);
		for (const label of [
			"Move column left",
			"Move column right",
			"Sort ascending",
			"Sort descending",
			"Align left",
			"Align center",
			"Align right",
		]) {
			expect(item(label), label).toBeDefined();
		}
		expect(item("Move row up")).toBeUndefined();
	});

	test("a body cell also offers row moves", () => {
		mount();
		openMenu(4);
		expect(item("Move row up")).toBeDefined();
		expect(item("Move row down")).toBeDefined();
	});

	test("moves that can't happen are disabled", () => {
		mount();
		openMenu(3); // first body row, first column
		expect(item("Move row up")?.disabled).toBe(true);
		expect(item("Move row down")?.disabled).toBe(false);
		expect(item("Move column left")?.disabled).toBe(true);
		expect(item("Move column right")?.disabled).toBe(false);
	});

	test("the last row / column can't move further", () => {
		mount();
		openMenu(8);
		expect(item("Move row down")?.disabled).toBe(true);
		expect(item("Move column right")?.disabled).toBe(true);
		expect(item("Move row up")?.disabled).toBe(false);
	});
});

describe("move row / column", () => {
	test("Move row down swaps it with the row below", () => {
		mount();
		choose(3, "Move row down");
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("Move row up swaps it with the row above", () => {
		mount();
		choose(6, "Move row up");
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("Move column right swaps it with the next column", () => {
		mount();
		choose(0, "Move column right");
		expect(table()).toBe("| b | a | c |\n| --- | --- | --- |\n| 2 | 1 | 3 |\n| 5 | 4 | 6 |");
	});

	test("Move column left swaps it with the previous column", () => {
		mount();
		choose(2, "Move column left");
		expect(table()).toBe("| a | c | b |\n| --- | --- | --- |\n| 1 | 3 | 2 |\n| 4 | 6 | 5 |");
	});
});

describe("sort by column", () => {
	test("ascending sorts numbers by value, not text", () => {
		mount(SORTABLE);
		choose(1, "Sort ascending"); // header cell of column v
		expect(table()).toBe("| n | v |\n| --- | --- |\n| y | 2 |\n| x | 10 |\n| z | 33 |");
	});

	test("descending reverses it", () => {
		mount(SORTABLE);
		choose(1, "Sort descending");
		expect(table()).toBe("| n | v |\n| --- | --- |\n| z | 33 |\n| x | 10 |\n| y | 2 |");
	});

	test("sorting from a body cell sorts by that cell's column", () => {
		mount(SORTABLE);
		choose(2, "Sort ascending"); // body cell "x", column n
		expect(table()).toBe("| n | v |\n| --- | --- |\n| x | 10 |\n| y | 2 |\n| z | 33 |");
	});

	test("empty cells sort last in either direction", () => {
		mount("| n |\n| --- |\n| b |\n|  |\n| a |\n\nafter\n");
		choose(0, "Sort ascending");
		expect(table()).toBe("| n |\n| --- |\n| a |\n| b |\n|  |");
		choose(0, "Sort descending");
		expect(table()).toBe("| n |\n| --- |\n| b |\n| a |\n|  |");
	});
});

describe("alignment", () => {
	test("Align center sets only that column", () => {
		mount();
		choose(1, "Align center");
		expect(table()).toBe("| a | b | c |\n| --- | :---: | --- |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |");
	});

	test("Align right and Align left", () => {
		mount();
		choose(0, "Align left");
		choose(2, "Align right");
		expect(table()).toBe("| a | b | c |\n| :--- | --- | ---: |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |");
	});

	test("it replaces an existing alignment", () => {
		mount("| a | b |\n| :-- | --: |\n| 1 | 2 |\n\nafter\n");
		choose(1, "Align center");
		expect(table()).toBe("| a | b |\n| :--- | :---: |\n| 1 | 2 |");
	});

	test("the new alignment is rendered on the column's cells", () => {
		mount();
		choose(1, "Align center");
		expect(cells().map((c) => c.dataset.align)).toEqual([
			undefined,
			"center",
			undefined,
			undefined,
			"center",
			undefined,
			undefined,
			"center",
			undefined,
		]);
	});
});
