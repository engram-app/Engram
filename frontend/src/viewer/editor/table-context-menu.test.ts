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
	test("a header cell offers every action, row actions included", () => {
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
		expect(item("Move row up")).toBeDefined();
		expect(item("Delete row")).toBeDefined();
	});

	test("a body cell also offers row moves", () => {
		mount();
		openMenu(4);
		expect(item("Move row up")).toBeDefined();
		expect(item("Move row down")).toBeDefined();
	});

	test("moves that can't happen are disabled", () => {
		mount();
		openMenu(0); // the header row, first column: nothing above or to the left
		expect(item("Move row up")?.disabled).toBe(true);
		expect(item("Move row down")?.disabled).toBe(false);
		expect(item("Move column left")?.disabled).toBe(true);
		expect(item("Move column right")?.disabled).toBe(false);
	});

	test("the first body row can move up (into the header)", () => {
		mount();
		openMenu(3);
		expect(item("Move row up")?.disabled).toBe(false);
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

describe("menu icons and semantics", () => {
	const items = () =>
		Array.from(document.querySelectorAll<HTMLButtonElement>(".cm-atomic-table-menu-item"));

	test("every item has an icon, and the label text is unchanged", () => {
		mount();
		openMenu(4);
		expect(items().length).toBeGreaterThan(10);
		for (const b of items()) {
			const icon = b.querySelector(".cm-atomic-table-menu-icon");
			expect(icon?.querySelector("svg"), b.textContent ?? "").not.toBeNull();
			expect(icon?.getAttribute("aria-hidden")).toBe("true");
			expect(icon?.textContent).toBe("");
		}
	});

	test("the icons are distinguishable: opposite actions get different glyphs", () => {
		mount();
		openMenu(4);
		const glyph = (label: string) => item(label)?.querySelector("svg")?.innerHTML;
		const pairs: Array<[string, string]> = [
			["Insert row above", "Insert row below"],
			["Insert column left", "Insert column right"],
			["Move row up", "Move row down"],
			["Move column left", "Move column right"],
			["Sort ascending", "Sort descending"],
			["Align left", "Align right"],
			["Align left", "Align center"],
		];
		for (const [a, b] of pairs) {
			expect(glyph(a), `${a} / ${b}`).toBeTruthy();
			expect(glyph(a), `${a} / ${b}`).not.toBe(glyph(b));
		}
		expect(glyph("Delete row")).toBe(glyph("Delete column"));
	});

	test("the menu is a menu: role=menu with role=menuitem buttons", () => {
		mount();
		openMenu(4);
		expect(document.querySelector(".cm-atomic-table-menu")?.getAttribute("role")).toBe("menu");
		expect(items().every((b) => b.getAttribute("role") === "menuitem")).toBe(true);
	});
});

describe("grouped menu: Row / Column / Sort / Align sub-menus", () => {
	const tick = () => new Promise<void>((resolve) => setTimeout(resolve, 0));
	const menu = () => document.querySelector(".cm-atomic-table-menu") as HTMLElement | null;
	const groups = () =>
		Array.from(document.querySelectorAll<HTMLElement>(".cm-atomic-table-menu-group"));
	const groupButton = (label: string) =>
		groups()
			.map((g) => g.querySelector<HTMLButtonElement>(":scope > .cm-atomic-table-menu-item"))
			.find((b) => b?.textContent === label);
	const submenu = (label: string) =>
		groupButton(label)?.parentElement?.querySelector<HTMLElement>(".cm-atomic-table-submenu");
	const isOpen = (label: string) => submenu(label)?.hidden === false;
	const keydown = (k: string) =>
		(document.activeElement ?? document).dispatchEvent(
			new KeyboardEvent("keydown", { key: k, bubbles: true, cancelable: true }),
		);
	const enter = (label: string) =>
		groupButton(label)?.parentElement?.dispatchEvent(new MouseEvent("pointerenter"));

	test("body and header cells both list Row, Column, Sort and Align", () => {
		mount();
		const labels = () => groups().map((g) => g.firstElementChild?.textContent);
		openMenu(4);
		expect(labels()).toEqual(["Row", "Column", "Sort", "Align"]);
		menu()?.remove();
		openMenu(1);
		expect(labels()).toEqual(["Row", "Column", "Sort", "Align"]);
	});

	test("groups are collapsed menu buttons", () => {
		mount();
		openMenu(4);
		for (const label of ["Row", "Column", "Sort", "Align"]) {
			const b = groupButton(label);
			expect(b?.getAttribute("aria-haspopup"), label).toBe("menu");
			expect(b?.getAttribute("aria-expanded"), label).toBe("false");
			expect(isOpen(label), label).toBe(false);
		}
	});

	test("leaf actions live inside their group's sub-menu", () => {
		mount();
		openMenu(4);
		const inside = (group: string, label: string) => submenu(group)?.contains(item(label) as Node);
		expect(inside("Row", "Move row up")).toBe(true);
		expect(inside("Row", "Delete row")).toBe(true);
		expect(inside("Column", "Insert column left")).toBe(true);
		expect(inside("Column", "Delete column")).toBe(true);
		expect(inside("Sort", "Sort ascending")).toBe(true);
		expect(inside("Align", "Align center")).toBe(true);
	});

	test("hovering a group opens its sub-menu and closes the others", () => {
		mount();
		openMenu(4);
		enter("Row");
		expect(isOpen("Row")).toBe(true);
		expect(groupButton("Row")?.getAttribute("aria-expanded")).toBe("true");
		enter("Column");
		expect(isOpen("Column")).toBe(true);
		expect(isOpen("Row")).toBe(false);
	});

	test("clicking a group toggles its sub-menu without closing the menu", () => {
		mount();
		openMenu(4);
		groupButton("Sort")?.click();
		expect(isOpen("Sort")).toBe(true);
		expect(menu()).not.toBeNull();
		groupButton("Sort")?.click();
		expect(isOpen("Sort")).toBe(false);
	});

	test("choosing a leaf runs it and closes the whole menu", () => {
		mount();
		choose(3, "Move row down");
		expect(menu()).toBeNull();
		expect(table()).toBe("| a | b | c |\n| --- | --- | --- |\n| 4 | 5 | 6 |\n| 1 | 2 | 3 |");
	});

	test("Escape closes an open sub-menu first, then the menu", async () => {
		mount();
		openMenu(4);
		await tick();
		enter("Row");
		keydown("Escape");
		expect(isOpen("Row")).toBe(false);
		expect(menu()).not.toBeNull();
		keydown("Escape");
		expect(menu()).toBeNull();
	});

	test("ArrowDown focuses the first group; ArrowRight opens it and focuses its first enabled item", async () => {
		mount();
		openMenu(0); // header row: "Move row up" is disabled
		await tick();
		keydown("ArrowDown");
		expect(document.activeElement).toBe(groupButton("Row"));
		keydown("ArrowRight");
		expect(isOpen("Row")).toBe(true);
		expect(document.activeElement).toBe(item("Insert row above"));
	});

	test("arrow navigation skips disabled items; ArrowLeft returns to the group", async () => {
		mount();
		openMenu(0);
		await tick();
		keydown("ArrowDown");
		keydown("ArrowRight");
		keydown("ArrowDown"); // Insert row below
		keydown("ArrowDown"); // skips the disabled "Move row up"
		expect(document.activeElement).toBe(item("Move row down"));
		keydown("ArrowLeft");
		expect(isOpen("Row")).toBe(false);
		expect(document.activeElement).toBe(groupButton("Row"));
	});
});

describe("the header row is not special: every action works on it", () => {
	test("Insert row above the header makes a new empty header; the old one becomes a body row", () => {
		mount();
		choose(0, "Insert row above");
		expect(table()).toBe(
			"|  |  |  |\n| --- | --- | --- |\n| a | b | c |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |",
		);
	});

	test("Insert row below the header adds the first body row", () => {
		mount();
		choose(0, "Insert row below");
		expect(table()).toBe(
			"| a | b | c |\n| --- | --- | --- |\n|  |  |  |\n| 1 | 2 | 3 |\n| 4 | 5 | 6 |",
		);
	});

	test("Move row down on the header swaps it with the first body row", () => {
		mount();
		choose(0, "Move row down");
		expect(table()).toBe("| 1 | 2 | 3 |\n| --- | --- | --- |\n| a | b | c |\n| 4 | 5 | 6 |");
	});

	test("Move row up on the first body row swaps it with the header", () => {
		mount();
		choose(3, "Move row up");
		expect(table()).toBe("| 1 | 2 | 3 |\n| --- | --- | --- |\n| a | b | c |\n| 4 | 5 | 6 |");
	});

	test("Delete row on the header promotes the first body row", () => {
		mount();
		choose(0, "Delete row");
		expect(table()).toBe("| 1 | 2 | 3 |\n| --- | --- | --- |\n| 4 | 5 | 6 |");
	});

	test("Delete row on a header with no body rows clears it instead (a table needs a header)", () => {
		mount("| a | b |\n| --- | --- |\n\nafter\n");
		choose(0, "Delete row");
		expect(table()).toBe("|  |  |\n| --- | --- |");
	});

	test("column alignment stays with its column through header row moves", () => {
		mount("| a | b |\n| :-- | --: |\n| 1 | 2 |\n\nafter\n");
		choose(0, "Move row down");
		expect(table()).toBe("| 1 | 2 |\n| :--- | ---: |\n| a | b |");
	});
});
