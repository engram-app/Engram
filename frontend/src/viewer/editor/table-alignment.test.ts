import { tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Column alignment (`:--`, `:--:`, `--:` in the separator row) must survive
// every edit. The table writer used to rewrite the separator as `---`, so the
// first edit in an aligned table silently dropped its alignment.
// Patched in patches/@atomic-editor%2Feditor@*.

const ALIGNED = "| a | b | c |\n| :-- | :-: | --: |\n| 1 | 2 | 3 |\n\nafter\n";

let view: EditorView;
afterEach(() => view?.destroy());

function mount(doc = ALIGNED) {
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

/** Type `text` at the end of cell `i` the way the browser would. */
function typeIn(i: number, text: string) {
	const cell = cells()[i];
	const source = cell?.querySelector<HTMLElement>(".cm-atomic-table-cell-source");
	if (!source) {
		throw new Error("no cell");
	}
	source.textContent = `${source.textContent}${text}`;
	const range = document.createRange();
	range.selectNodeContents(source);
	range.collapse(false);
	window.getSelection()?.removeAllRanges();
	window.getSelection()?.addRange(range);
	source.dispatchEvent(new Event("input", { bubbles: true }));
}

describe("column alignment survives edits", () => {
	test("typing in a cell keeps the separator row's alignment", () => {
		mount();
		typeIn(4, "x");
		expect(table()).toBe("| a | b | c |\n| :--- | :---: | ---: |\n| 1 | 2x | 3 |");
	});

	test("an unaligned table still writes plain separators", () => {
		mount("| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter\n");
		typeIn(2, "x");
		expect(table()).toBe("| a | b |\n| --- | --- |\n| 1x | 2 |");
	});

	test("only some columns aligned: the rest stay plain", () => {
		mount("| a | b | c |\n| --- | :-: | --- |\n| 1 | 2 | 3 |\n\nafter\n");
		typeIn(3, "x");
		expect(table()).toBe("| a | b | c |\n| --- | :---: | --- |\n| 1x | 2 | 3 |");
	});

	test("adding a row keeps alignment", () => {
		mount();
		view.dom.querySelector<HTMLButtonElement>(".cm-atomic-table-add-row")?.click();
		expect(table()).toBe("| a | b | c |\n| :--- | :---: | ---: |\n| 1 | 2 | 3 |\n|  |  |  |");
	});

	test("adding a column keeps the others' alignment; the new one is plain", () => {
		mount();
		view.dom.querySelector<HTMLButtonElement>(".cm-atomic-table-add-col")?.click();
		expect(table()).toBe("| a | b | c |  |\n| :--- | :---: | ---: | --- |\n| 1 | 2 | 3 |  |");
	});

	test("deleting a column takes its alignment with it", () => {
		mount();
		const pointer = (el: Element, type: string, buttons: number) =>
			el.dispatchEvent(
				new MouseEvent(type, { bubbles: true, cancelable: true, button: 0, buttons }),
			);
		const src = (i: number) => cells()[i]?.querySelector(".cm-atomic-table-cell-source") as Element;
		pointer(src(1), "pointerdown", 1);
		pointer(src(4), "pointermove", 1);
		pointer(src(4), "pointerup", 0);
		view.dom
			.querySelector(".cm-atomic-table")
			?.dispatchEvent(
				new KeyboardEvent("keydown", { key: "Backspace", bubbles: true, cancelable: true }),
			);
		expect(table()).toBe("| a | c |\n| :--- | ---: |\n| 1 | 3 |");
	});
});

describe("alignment is rendered", () => {
	test("each cell carries its column's alignment", () => {
		mount();
		expect(cells().map((c) => c.dataset.align)).toEqual([
			"left",
			"center",
			"right",
			"left",
			"center",
			"right",
		]);
	});

	test("an unaligned column has no alignment attribute", () => {
		mount("| a | b |\n| --- | --: |\n| 1 | 2 |\n\nafter\n");
		expect(cells().map((c) => c.dataset.align)).toEqual([undefined, "right", undefined, "right"]);
	});

	test("changing the separator row in the document re-renders the alignment", () => {
		mount("| a | b |\n| --- | --- |\n| 1 | 2 |\n\nafter\n");
		const from = view.state.doc.toString().indexOf("| --- | --- |");
		view.dispatch({
			changes: { from, to: from + "| --- | --- |".length, insert: "| :-: | --: |" },
		});
		expect(cells().map((c) => c.dataset.align)).toEqual(["center", "right", "center", "right"]);
	});
});
