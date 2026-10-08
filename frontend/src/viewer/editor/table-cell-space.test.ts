import { tables } from "@atomic-editor/editor";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { EditorState } from "@codemirror/state";
import { EditorView } from "@codemirror/view";
import { afterEach, describe, expect, test } from "vitest";

// Regression: typing a space in a table cell did nothing / moved the caret.
// @atomic-editor/editor's cell `commit()` trimmed the cell text and rebuilt
// the DOM on every keystroke, so a just-typed trailing space vanished and the
// restored caret offset overshot. Fixed by patches/@atomic-editor%2Feditor@*.

const DOC = "| a | b |\n| --- | --- |\n| one | two |\n";

let view: EditorView;
afterEach(() => view?.destroy());

// Mount `doc` and return the editable source of body-row cell `index` (0-based).
function mountCell(doc: string, index: number): HTMLElement {
	view = new EditorView({
		state: EditorState.create({
			doc,
			extensions: [markdown({ base: markdownLanguage }), tables({})],
		}),
		parent: document.body,
	});
	const cells = view.dom.querySelectorAll<HTMLElement>(".cm-atomic-table-cell-source");
	const cell = cells[index + 2]; // skip the two header cells
	if (!cell) {
		throw new Error("table widget did not render");
	}
	return cell;
}

function caretOffset(el: HTMLElement): number | null {
	const sel = window.getSelection();
	if (!sel || sel.rangeCount === 0) {
		return null;
	}
	const r = sel.getRangeAt(0).cloneRange();
	const pre = document.createRange();
	pre.selectNodeContents(el);
	pre.setEnd(r.startContainer, r.startOffset);
	return pre.toString().length;
}

// Simulate the browser typing `text` at the caret: mutate the DOM, move the
// caret past it, fire `input`.
function type(el: HTMLElement, text: string) {
	const offset = caretOffset(el) ?? (el.textContent ?? "").length;
	const full = el.textContent ?? "";
	const next = full.slice(0, offset) + text + full.slice(offset);
	el.textContent = next;
	const node = el.firstChild as Text;
	const range = document.createRange();
	range.setStart(node, offset + text.length);
	range.collapse(true);
	const sel = window.getSelection();
	sel?.removeAllRanges();
	sel?.addRange(range);
	el.dispatchEvent(new Event("input", { bubbles: true }));
}

function caretAt(el: HTMLElement, offset: number) {
	el.focus();
	const walker = document.createTreeWalker(el, NodeFilter.SHOW_TEXT);
	let remaining = offset;
	let node = walker.nextNode() as Text | null;
	while (node && remaining > node.data.length) {
		remaining -= node.data.length;
		node = walker.nextNode() as Text | null;
	}
	const range = document.createRange();
	if (node) {
		range.setStart(node, remaining);
	} else {
		range.setStart(el, 0); // empty cell: no text node yet
	}
	range.collapse(true);
	const sel = window.getSelection();
	sel?.removeAllRanges();
	sel?.addRange(range);
}

describe("table cell typing", () => {
	test("a space typed at the end of a cell stays in the cell", () => {
		const cell = mountCell(DOC, 0); // "one"
		caretAt(cell, 3);
		type(cell, " ");
		expect(cell.textContent).toBe("one ");
		expect(caretOffset(cell)).toBe(4);
	});

	test("typing a word after a trailing space keeps the space", () => {
		const cell = mountCell(DOC, 0);
		caretAt(cell, 3);
		type(cell, " ");
		type(cell, "x");
		expect(cell.textContent).toBe("one x");
		expect(caretOffset(cell)).toBe(5);
	});

	test("a space typed mid-cell keeps the caret after the space", () => {
		const cell = mountCell(DOC, 0);
		caretAt(cell, 1);
		type(cell, " ");
		expect(cell.textContent).toBe("o ne");
		expect(caretOffset(cell)).toBe(2);
	});

	test("a space in an empty cell is kept", () => {
		const cell = mountCell("| a | b |\n| --- | --- |\n|  | two |\n", 0);
		caretAt(cell, 0);
		type(cell, " ");
		expect(cell.textContent).toBe(" ");
	});

	test("trailing space never reaches the markdown doc", () => {
		const cell = mountCell(DOC, 0);
		caretAt(cell, 3);
		type(cell, " ");
		expect(view.state.doc.toString()).toBe(DOC);
	});
});
